#!/usr/bin/env python3
"""
load_sample_data.py - load the repo's demo CSVs into a Fabric lakehouse.

Writes every file in sample/ as a Delta table at Tables/<schema>/<table> of the
given lakehouse, under exactly the schema and table names the dbt _sources.yml
files resolve (raw_sales, raw_hr, mdm). No Spark session and no notebook item is
involved - Delta is written straight to OneLake over its ADLS endpoint with
delta-rs, so this runs on a laptop or a CI agent in a few seconds.

Called by infra/sample_data.tf during `terraform apply`, and runnable by hand:

    python infra/scripts/load_sample_data.py \
        --workspace-id <workspace guid> --lakehouse-id <lakehouse guid>

Get the GUIDs from Terraform:

    terraform -chdir=infra output -json ci_variables

Authentication follows the same order the rest of the repo uses:

  1. FABRIC_CLIENT_ID / FABRIC_CLIENT_SECRET / FABRIC_TENANT_ID   (Terraform SP)
  2. DBT_SP_CLIENT_ID / DBT_SP_CLIENT_SECRET / DBT_SP_TENANT_ID   (pipeline SP)
  3. the signed-in Azure CLI user (`az login`)

--auth pins one of them instead. This matters because the identity here must be
the one that owns the workspaces, and it is easy for the two to diverge: the
provider runs under `az login` whenever use_cli is true (the default) and
ignores any exported FABRIC_CLIENT_ID, while step 1 above would pick that same
exported SP up. Terraform then creates workspaces as you and loads data as the
SP, which 403s on every environment the SP holds no role in. sample_data.tf
passes --auth cli under use_cli for exactly that reason.

The principal needs write access to the workspace (Contributor or above).

Dependencies are in requirements/requirements-setup.txt - the one-time
provisioning set, kept apart from requirements.txt so a day-to-day
dbt environment stays lean.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

# Imported up front so a missing dependency fails with an actionable message
# instead of a traceback in the middle of a terraform apply.
try:
    import pyarrow as pa
    from pyarrow import csv as pa_csv
    from deltalake import write_deltalake
    from azure.identity import AzureCliCredential, ClientSecretCredential
except ModuleNotFoundError as exc:  # pragma: no cover - environment problem
    sys.exit(
        f"Missing dependency '{exc.name}'. Install the loader's requirements:\n"
        "    pip install -r requirements/requirements-setup.txt\n"
        "Or set load_sample_data = false in infra/terraform.tfvars to skip this step."
    )

# OneLake speaks the ADLS Gen2 protocol under a fixed host; the workspace is the
# filesystem and the lakehouse GUID the first path segment.
ONELAKE_HOST = "onelake.dfs.fabric.microsoft.com"
STORAGE_SCOPE = "https://storage.azure.com/.default"

# A workspace role reaches OneLake seconds after the control plane accepts it,
# so the first write backs off over ~30s (5 + 10 + 15) before giving up.
PERMISSION_RETRIES = 4
PERMISSION_RETRY_DELAY = 5

# Column types are declared rather than inferred. Inference would make the
# Delta types depend on the demo rows that happen to be present - an all-empty
# active_to column would land as null-typed, and the SQL endpoint would then
# expose something the staging models cannot cast.
#
# Timestamps are declared naive here and cast to UTC before writing: a
# timezone-less Arrow timestamp becomes Delta timestampNtz, which needs a
# reader feature the Fabric SQL analytics endpoint does not always expose.
_STR = pa.string()
_DATE = pa.date32()
_TS = pa.timestamp("us")
_INT = pa.int32()
_MONEY = pa.decimal128(18, 2)

TABLES: tuple[dict, ...] = (
    {
        "csv": "raw_sales_customers.csv",
        "schema": "raw_sales",
        "table": "raw_sales_customers",
        "columns": {
            "customer_id": _STR,
            "full_name": _STR,
            "email": _STR,
            "country_code": _STR,
            "city": _STR,
            "created_at": _TS,
            "updated_at": _TS,
            "_loaded_at": _TS,
        },
    },
    {
        "csv": "raw_sales_products.csv",
        "schema": "raw_sales",
        "table": "raw_sales_products",
        "columns": {
            "product_id": _STR,
            "product_name": _STR,
            "category_code": _STR,
            "unit_price": _MONEY,
            "active_from": _DATE,
            "active_to": _DATE,
            "updated_at": _TS,
            "_loaded_at": _TS,
        },
    },
    {
        "csv": "raw_sales_orders.csv",
        "schema": "raw_sales",
        "table": "raw_sales_orders",
        "columns": {
            "order_id": _STR,
            "customer_id": _STR,
            "sales_rep_id": _STR,
            "order_date": _DATE,
            "status": _STR,
            "currency_code": _STR,
            "updated_at": _TS,
            "_loaded_at": _TS,
        },
    },
    {
        "csv": "raw_sales_order_lines.csv",
        "schema": "raw_sales",
        "table": "raw_sales_order_lines",
        "columns": {
            "order_id": _STR,
            "line_id": _INT,
            "product_id": _STR,
            "quantity": _INT,
            "unit_price": _MONEY,
            "discount_amount": _MONEY,
            "updated_at": _TS,
            "_loaded_at": _TS,
        },
    },
    {
        "csv": "raw_hr_sales_reps.csv",
        "schema": "raw_hr",
        "table": "raw_hr_sales_reps",
        "columns": {
            "sales_rep_id": _STR,
            "sales_rep_name": _STR,
            "region": _STR,
            "team_name": _STR,
            "manager_name": _STR,
            "updated_at": _TS,
            "_loaded_at": _TS,
        },
    },
    {
        "csv": "mdm_product_category_mapping.csv",
        "schema": "mdm",
        "table": "mdm_product_category_mapping",
        "columns": {
            "category_code": _STR,
            "category_name": _STR,
            "category_group": _STR,
            # 0/1 in the CSV; the staging model casts it to bit.
            "is_budget_relevant": _INT,
            "mdm_owner": _STR,
            "effective_from": _DATE,
            "effective_to": _DATE,
            "updated_at": _TS,
            "_loaded_at": _TS,
        },
    },
)


def utc_schema(schema: pa.Schema) -> pa.Schema:
    """Return `schema` with every naive timestamp reinterpreted as UTC."""
    fields = [
        field.with_type(pa.timestamp(field.type.unit, tz="UTC"))
        if pa.types.is_timestamp(field.type) and field.type.tz is None
        else field
        for field in schema
    ]
    return pa.schema(fields)


def read_csv(path: Path, columns: dict[str, pa.DataType]) -> pa.Table:
    """Read one demo CSV into an Arrow table matching the declared columns."""
    read_schema = pa.schema(columns)

    arrow = pa_csv.read_csv(
        path,
        read_options=pa_csv.ReadOptions(encoding="utf8"),
        convert_options=pa_csv.ConvertOptions(
            column_types=columns,
            # Empty fields are nulls, not empty strings - active_to and
            # effective_to are blank for every currently-valid row.
            null_values=[""],
            strings_can_be_null=True,
        ),
    )

    missing = [name for name in columns if name not in arrow.column_names]
    unexpected = [name for name in arrow.column_names if name not in columns]
    if missing or unexpected:
        raise ValueError(
            f"{path.name} does not match the declared columns "
            f"(missing: {missing or 'none'}, unexpected: {unexpected or 'none'}). "
            "Update TABLES in this script and the matching _sources.yml together."
        )

    # select() fixes the column order; cast() pins the exact Delta types.
    return arrow.select(list(columns)).cast(utc_schema(read_schema))


def acquire_token(auth: str = "auto") -> tuple[str, str]:
    """Return an OneLake storage token and a label for the identity used."""
    if auth != "cli":
        for prefix in ("FABRIC", "DBT_SP"):
            client_id = os.environ.get(f"{prefix}_CLIENT_ID")
            client_secret = os.environ.get(f"{prefix}_CLIENT_SECRET")
            tenant_id = os.environ.get(f"{prefix}_TENANT_ID") or os.environ.get("ARM_TENANT_ID")
            if client_id and client_secret and tenant_id:
                credential = ClientSecretCredential(
                    tenant_id=tenant_id, client_id=client_id, client_secret=client_secret
                )
                return credential.get_token(STORAGE_SCOPE).token, f"{prefix} service principal"

        if auth == "sp":
            sys.exit(
                "--auth sp given, but no complete service principal in the environment. "
                "Export FABRIC_CLIENT_ID / FABRIC_CLIENT_SECRET / FABRIC_TENANT_ID "
                "(or the DBT_SP_ equivalents)."
            )

    # No service principal in the environment: fall back to `az login`, which is
    # what infra/README.md documents as the interactive default.
    return AzureCliCredential().get_token(STORAGE_SCOPE).token, "Azure CLI user"


def is_forbidden(exc: BaseException) -> bool:
    """True for the 403 OneLake raises when the caller holds no workspace role."""
    text = str(exc)
    return "403" in text or "Forbidden" in text


def write_with_retry(table_uri, arrow, *, attempts: int, **kwargs) -> None:
    """write_deltalake, retrying a 403 that is only a role not yet propagated.

    A workspace role assignment reaches the OneLake data plane a few seconds
    after the control plane accepts it, so an apply that grants the role and
    loads in the same graph can race it. Retrying costs seconds; failing the
    apply costs a re-run.
    """
    for attempt in range(1, attempts + 1):
        try:
            write_deltalake(table_uri, arrow, **kwargs)
            return
        except OSError as exc:
            if attempt == attempts or not is_forbidden(exc):
                raise
            delay = PERMISSION_RETRY_DELAY * attempt
            print(
                f"  403 from OneLake (attempt {attempt}/{attempts}); a just-granted "
                f"role may not have propagated - retrying in {delay}s"
            )
            time.sleep(delay)


def forbidden_message(exc: OSError, identity: str, args: argparse.Namespace) -> str:
    """Turn a delta-rs 403 into the actionable version of itself."""
    return (
        f"\n403 Forbidden from OneLake writing to workspace {args.workspace_id}, "
        f"lakehouse {args.lakehouse_id}.\n\n"
        f"Authenticated as: {identity}\n\n"
        "That identity holds no role on this workspace, or too weak a one - "
        "OneLake needs Contributor or above.\n"
        "The usual cause is an identity mismatch: Terraform runs under `az login` "
        "whenever use_cli is true (the default), so it creates the workspaces as "
        "you, while an exported FABRIC_CLIENT_ID makes this loader write as the "
        "service principal instead. Either:\n"
        "  - pass --auth cli to load as the signed-in user, or\n"
        "  - grant the service principal a role on every environment "
        "(dbt_sp_role in terraform.tfvars; dev defaults to null).\n\n"
        "Check who holds what:\n"
        f"  az rest --method get --url https://api.fabric.microsoft.com/v1/workspaces/"
        f"{args.workspace_id}/roleAssignments --resource https://api.fabric.microsoft.com\n\n"
        f"Original error:\n{exc}"
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    default_sample_dir = Path(__file__).resolve().parents[2] / "sample"

    parser = argparse.ArgumentParser(
        description="Load the demo CSVs in sample/ into a Fabric lakehouse as Delta tables.",
    )
    parser.add_argument("--workspace-id", required=True, help="Fabric workspace GUID.")
    parser.add_argument(
        "--lakehouse-id",
        required=True,
        help="Source lakehouse item GUID (LH_source), not its display name.",
    )
    parser.add_argument(
        "--sample-dir",
        type=Path,
        default=default_sample_dir,
        help=f"Directory holding the demo CSVs (default: {default_sample_dir}).",
    )
    parser.add_argument(
        "--mode",
        choices=("overwrite", "append", "error"),
        default="overwrite",
        help="Delta write mode. overwrite (default) makes the load idempotent.",
    )
    parser.add_argument(
        "--table",
        action="append",
        dest="tables",
        metavar="NAME",
        help="Load only this table; repeatable. Defaults to all six.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Read and validate the CSVs, print what would be written, write nothing.",
    )
    parser.add_argument(
        "--auth",
        choices=("auto", "cli", "sp"),
        default="auto",
        help=(
            "Identity to write as. auto (default) prefers a service principal in "
            "the environment and falls back to the Azure CLI; cli forces `az login` "
            "even with FABRIC_CLIENT_ID exported; sp requires a service principal. "
            "Must match the identity that owns the workspaces."
        ),
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    sample_dir = args.sample_dir.resolve()
    if not sample_dir.is_dir():
        sys.exit(f"Sample directory not found: {sample_dir}")

    selected = TABLES
    if args.tables:
        wanted = set(args.tables)
        selected = tuple(spec for spec in TABLES if spec["table"] in wanted)
        unknown = wanted - {spec["table"] for spec in TABLES}
        if unknown:
            sys.exit(f"Unknown table(s): {', '.join(sorted(unknown))}")

    # Read and validate everything before the first write, so a malformed CSV
    # cannot leave the lakehouse half loaded.
    loaded: list[tuple[dict, pa.Table]] = []
    for spec in selected:
        path = sample_dir / spec["csv"]
        if not path.is_file():
            sys.exit(f"Missing demo CSV: {path}")
        try:
            loaded.append((spec, read_csv(path, spec["columns"])))
        except Exception as exc:
            sys.exit(f"Failed to read {path.name}: {exc}")

    print(f"Read {len(loaded)} CSV file(s) from {sample_dir}")

    if args.dry_run:
        for spec, arrow in loaded:
            print(f"  would write {spec['schema']}.{spec['table']}: {arrow.num_rows} row(s)")
        return 0

    token, identity = acquire_token(args.auth)
    print(f"Authenticated as {identity}.")

    storage_options = {
        "bearer_token": token,
        # Tells delta-rs the account is OneLake rather than a storage account,
        # so it keeps the workspace-as-filesystem URL shape intact.
        "use_fabric_endpoint": "true",
    }

    base_uri = f"abfss://{args.workspace_id}@{ONELAKE_HOST}/{args.lakehouse_id}"

    first = True
    for spec, arrow in loaded:
        table_uri = f"{base_uri}/Tables/{spec['schema']}/{spec['table']}"
        write_kwargs = {}
        if args.mode == "overwrite":
            # Lets a changed CSV change the column set, not just the rows.
            write_kwargs["schema_mode"] = "overwrite"

        try:
            # Only the first write waits out a propagation lag: once one table
            # lands, the role is live and a later 403 is a real permission fault.
            write_with_retry(
                table_uri,
                arrow,
                mode=args.mode,
                storage_options=storage_options,
                attempts=PERMISSION_RETRIES if first else 1,
                **write_kwargs,
            )
        except OSError as exc:
            if not is_forbidden(exc):
                raise
            sys.exit(forbidden_message(exc, identity, args))
        first = False
        print(f"  {spec['schema']}.{spec['table']}: {arrow.num_rows} row(s) written")

    print(
        f"Done. {len(loaded)} table(s) written to lakehouse {args.lakehouse_id}.\n"
        "The SQL analytics endpoint discovers new tables asynchronously - give it "
        "a minute before the first dbt run."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
