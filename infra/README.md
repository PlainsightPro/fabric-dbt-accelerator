# infra/ — Fabric workspaces for the accelerator

Terraform for the Fabric side of the CI/CD setup: one workspace per dbt target,
each with the warehouse dbt builds into and the lakehouse(s) it reads from and
deploys to. The outputs hand back every pipeline variable under the exact name
the workflows read it by.

Provisioning the **capacity itself is out of scope** — this module assigns
workspaces to a capacity that already exists.

## What it creates

| Workspace | Warehouse | Source lakehouse | Code lakehouse | dbt SP role |
| --------- | --------- | ---------------- | -------------- | ----------- |
| `<prefix>-dev` | `WH_dev` | `LH_source` | — | none |
| `<prefix>-ci` | `WH_ci` | `LH_source` | — | Contributor |
| `<prefix>-accept` | `WH_accept` | `LH_source` | `LH_dbt_code` | Contributor |
| `<prefix>-prod` | `WH_prod` | `LH_source` | `LH_dbt_code` | Contributor |

Fourteen items in total: 4 workspaces, 4 warehouses, 6 lakehouses, plus 3 role
assignments. Each `LH_source` is then loaded with the demo data from
[`../sample/`](../sample/) — see [*Sample data*](#sample-data) below.

Two design points worth knowing before you change anything:

- **The source lakehouse has the same name in every workspace.** The
  `_sources.yml` files resolve `[LH_source].[raw_sales].[table]`, so one
  `DBT_FABRIC_SOURCE_DATABASE` value works for every target and only the
  workspace differs.
- **CI gets its own workspace.** Fabric only allows cross-database queries
  within one workspace, so the CI warehouse must sit beside a source lakehouse;
  and `build-dev` rewrites the whole bronze/silver/gold layer on every merge to
  `dev`, which must never land in an environment anyone reads.
  See [`../docs/ci_architecture.md`](../docs/ci_architecture.md).

## Prerequisites

1. An existing Fabric capacity, **Active** (not paused).
2. Your account added as a **capacity administrator** on it — required both to
   assign workspaces to the capacity and to resolve `capacity_name` through the
   `fabric_capacity` data source. Azure portal → the capacity → *Capacity
   administrators*. Being an Azure subscription Owner is **not** sufficient; the
   capacity admin list is separate, and a capacity you are not an admin on is
   invisible to the lookup.
3. Terraform >= 1.9 and the Azure CLI.
4. Service-principal runs only: **"Service principals can use Fabric APIs"**
   enabled in the Fabric admin portal, scoped to a group containing the SP.
5. For the sample-data load (on by default): `python` on `PATH` with
   `pip install -r ../requirements/requirements-setup.txt`. Skip it with
   `-var load_sample_data=false`.

## Usage

Authentication defaults to the Azure CLI — no exports, no provider edits:

```bash
az login --tenant <tenant guid>
az account show          # confirm the right tenant

cd infra
cp terraform.tfvars.example terraform.tfvars   # then set capacity_name
terraform init
terraform plan
terraform apply
```

List the capacity names you can actually see (if yours is missing, you are not a
capacity admin on it):

```bash
az rest --method get --url https://api.fabric.microsoft.com/v1/capacities \
  --resource https://api.fabric.microsoft.com \
  --query "value[].{name:displayName, state:state, sku:sku}" -o table
```

## Switching to a service principal or OIDC later

The provider is driven entirely by variables, so CI never edits a `.tf` file.
Secrets stay in the environment and out of both the config and the state.

```bash
# Service principal with a client secret
export FABRIC_CLIENT_ID=<appId>
export FABRIC_CLIENT_SECRET=<password>
terraform plan -var use_cli=false -var tenant_id=<tenant guid>

# GitHub Actions with federated credentials (no secret at all)
terraform plan -var use_cli=false -var use_oidc=true -var tenant_id=<tenant guid>
```

Or set `TF_VAR_use_cli=false` / `TF_VAR_use_oidc=true` as workflow env vars.
`use_cli` and `use_oidc` are mutually exclusive and validated as such.

Where the CI principal is not a capacity admin, swap `capacity_name` for
`capacity_id` to skip the lookup entirely — see *Rough edges* below.

## Wiring the results into GitHub

```bash
terraform output -raw gh_commands      # paste-ready gh variable/secret set lines
terraform output -json ci_variables    # everything, as JSON
terraform output -raw dev_env_file     # the local .env block
```

| Where | Variable | Comes from |
| ----- | -------- | ---------- |
| Repo variable | `DBT_FABRIC_HOST_CI` | ci warehouse connection string |
| Repo variable | `DBT_FABRIC_DATABASE_CI` | ci warehouse name |
| Repo variable | `DBT_FABRIC_SOURCE_DATABASE_CI` | ci source lakehouse name |
| Repo secret | `DBT_SP_TENANT_ID` / `DBT_SP_CLIENT_ID` / `DBT_SP_CLIENT_SECRET` | **not from Terraform** — your service principal |
| Env `accept`/`prod` | `DBT_FABRIC_HOST`, `DBT_FABRIC_DATABASE`, `DBT_FABRIC_SOURCE_DATABASE`, `DBT_FABRIC_WORKSPACE`, `DBT_FABRIC_DATALAKE_ID` | that environment's items |
| Local `.env` | `DBT_FABRIC_HOST_DEV`, `DBT_FABRIC_DATABASE_DEV`, `DBT_FABRIC_SOURCE_DATABASE` | dev workspace |

The credentials are kept out of Terraform on purpose: a `client_secret`
variable would sit in plaintext in the state file forever.

`DBT_FABRIC_WORKSPACE` is emitted as the workspace **GUID**, not its name —
[`../cicd/scripts/deploy_to_onelake.sh`](../cicd/scripts/deploy_to_onelake.sh)
interpolates it straight into a OneLake URL without encoding it.

## Sample data

With `load_sample_data = true` (the default), the apply ends by writing the six
CSVs in [`../sample/`](../sample/) into every `LH_source` as Delta tables, using
exactly the schema and table names the `_sources.yml` files resolve:

| Schema | Tables |
| ------ | ------ |
| `raw_sales` | `raw_sales_customers`, `raw_sales_products`, `raw_sales_orders`, `raw_sales_order_lines` |
| `raw_hr` | `raw_hr_sales_reps` |
| `mdm` | `mdm_product_category_mapping` |

[`scripts/load_sample_data.py`](scripts/load_sample_data.py) does the work.
It writes Delta straight to OneLake over the ADLS endpoint with delta-rs — no
Spark session, no notebook item, no capacity time — and declares every column
type rather than inferring it, so the SQL analytics endpoint exposes the
`date` / `datetime2` / `decimal(18,2)` types the staging models cast from.

Terraform re-runs the load whenever a CSV or the loader changes, and the write
is an overwrite, so applying repeatedly is safe. Terraform tracks only *that*
the load ran — the table contents are data, outside its state.

Run it by hand against any lakehouse:

```bash
pip install -r ../requirements/requirements-setup.txt

python scripts/load_sample_data.py \
    --workspace-id <workspace guid> --lakehouse-id <LH_source guid>

# Validate the CSVs without writing anything:
python scripts/load_sample_data.py --workspace-id x --lakehouse-id y --dry-run
```

Authentication mirrors the rest of the repo: `FABRIC_CLIENT_ID` /
`FABRIC_CLIENT_SECRET` / `FABRIC_TENANT_ID`, else `DBT_SP_*`, else the
signed-in Azure CLI user. `local-exec` inherits the environment, so a service
principal exported for Terraform is picked up automatically.

**Turn it off for real data:** `load_sample_data = false`. The loader only ever
touches those six tables, but demo rows have no place in a lakehouse fed by a
real pipeline.

## Variables

| Name | Default | Notes |
| ---- | ------- | ----- |
| `tenant_id` | `null` | Optional under CLI auth — `az login --tenant` already pins it. |
| `use_cli` | `true` | Azure CLI auth. The default. |
| `use_oidc` | `false` | GitHub Actions federated credentials. Mutually exclusive with `use_cli`. |
| `client_id` / `client_secret` | `null` | Prefer `FABRIC_CLIENT_ID` / `FABRIC_CLIENT_SECRET`. Never put the secret in a file. |
| `capacity_name` | `null` | The normal choice; resolved via the `fabric_capacity` data source. Needs capacity admin. |
| `capacity_id` | `null` | Escape hatch when the principal cannot list capacities. Set exactly one of the two. |
| `dbt_service_principal_object_id` | `null` | The SP's **object** id. Required only if any `dbt_sp_role` is set. |
| `workspace_prefix` | `dbt-accelerator` | Workspace names become `<prefix>-<key>`. |
| `source_lakehouse_name` | `LH_source` | Must equal `DBT_FABRIC_SOURCE_DATABASE`. |
| `code_lakehouse_name` | `LH_dbt_code` | Deployment target for `Files/dbt_project`. |
| `warehouse_collation` | `Latin1_General_100_BIN2_UTF8` | ForceNew. |
| `load_sample_data` | `true` | Load `../sample/*.csv` into every `LH_source`. Needs python + `requirements-setup.txt`. False for real data. |
| `python_command` | `python` | Interpreter for the loader. Point at the venv's python where `python` is not on `PATH`. |
| `environments` | dev/ci/accept/prod | Per-entry: `display_name`, `warehouse_name`, `capacity_id`, `dbt_sp_role`, `deploy_target`. |

## What this does NOT do

- **It does not load anything beyond the demo CSVs.** The sample-data load
  covers the six tables in [`../sample/`](../sample/) and nothing else; real
  source data arrives through whatever pipeline feeds the client's lakehouse.
  With `load_sample_data = false` the lakehouses come out empty, and until the
  source tables exist, CI's `assert_cross_db_access` smoke test still passes —
  it only reads `INFORMATION_SCHEMA` — while `dbt build` fails on missing
  sources.
- **It does not create the capacity**, the Entra app registration, the GitHub
  repository, its branches or its protection rules. See
  [`../docs/CLIENT_SETUP.md`](../docs/CLIENT_SETUP.md) for the surrounding steps.
- **It does not schedule anything in Fabric.** accept and prod are executed by a
  Fabric-side runtime on its own schedule, configured outside this repo.

## Rough edges

- **SQL endpoints provision asynchronously.** `apply` can return before a
  lakehouse's SQL analytics endpoint is queryable, so a dbt run immediately
  afterwards may fail and then succeed minutes later. Check
  `terraform output lakehouse_sql_endpoints`.
- **Lakehouse tables appear in SQL a moment after they are written.** The
  sample-data load finishes as soon as the Delta files land in OneLake, but the
  SQL analytics endpoint discovers them on its own metadata sync. A `dbt build`
  started in the same breath as `terraform apply` can still see missing
  sources; wait a minute and re-run.
- **`enable_schemas` and `collation_type` are ForceNew.** Editing either
  destroys and recreates the item, taking its data with it. Both are set
  correctly at creation for exactly this reason.
- **The capacity data source has an open crash report** under service-principal
  auth when the principal cannot list capacities
  ([microsoft/terraform-provider-fabric#455](https://github.com/microsoft/terraform-provider-fabric/issues/455)).
  Interactive CLI runs by a capacity admin are unaffected. If CI hits it, set
  `capacity_id` instead and the lookup never happens.
- **State lives locally, inside OneDrive.** [`versions.tf`](versions.tf) carries
  a commented `backend "azurerm"` block with the `az` commands to create the
  container. Enable it before the first `apply` — OneDrive sync conflicts on a
  state file are unpleasant, and the file holds every connection string.
- **Do not give the Terraform principal a `dbt_sp_role`.** It is already
  workspace Admin as the creator; a second assignment for the same object id
  conflicts. When the dbt SP and the Terraform SP are the same app — which is
  what `CLIENT_SETUP.md` sets up — leave every `dbt_sp_role` at `null`.
- **Destroying is destructive in the obvious way.** `terraform destroy` removes
  workspaces along with every warehouse, lakehouse and table inside them.
