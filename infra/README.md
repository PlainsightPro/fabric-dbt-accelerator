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
| `<prefix>-dev` | `WH_dev` | `LH_source` | `LH_dbt_code` | Contributor |
| `<prefix>-ci` | `WH_ci` | `LH_source` | — | Contributor |
| `<prefix>-accept` | `WH_accept` | `LH_source` | `LH_dbt_code` | Contributor |
| `<prefix>-prod` | `WH_prod` | `LH_source` | `LH_dbt_code` | Contributor |

Nineteen items in total: 4 workspaces, 4 warehouses, 7 lakehouses, plus 4 role
assignments. Each `LH_source` is then loaded with the demo data from
[`../sample/`](../sample/) — see [*Sample data*](#sample-data) below.

The four role assignments are what let the pipelines in
[`../.github/workflows/`](../.github/workflows/) reach Fabric at all. Without
them the pipelines authenticate successfully and then fail on the first query,
because the principal holds no role on the workspace it just connected to.

`dev` carries a code lakehouse and a role assignment because it is a deploy
target too: `deploy-dev` ships the project there so a Fabric-side schedule can
run it. That scheduled run is the only place incremental models take their
merge path — every pipeline target builds `--full-refresh`. Developers still
work in `dev` interactively under their own `dev_<username>_*` schemas, which
the scheduled run never touches. To opt out, set `dev`'s `dbt_sp_role = null`
in `environments` and the lakehouse, role assignment and GitHub Environment all
disappear with it.

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
2. Your account added as a **capacity administrator** on it — required to assign
   workspaces to the capacity at all, and again to resolve `capacity` when you
   give it as a display name rather than a GUID. Azure portal → the capacity →
   *Capacity administrators*. Being an Azure subscription Owner is **not**
   sufficient; the capacity admin list is separate, and a capacity you are not
   an admin on is invisible to the lookup.
3. Terraform >= 1.9 and the Azure CLI.
4. Service-principal runs only: **"Service principals can use Fabric APIs"**
   enabled in the Fabric admin portal, scoped to a group containing the SP.
5. For the sample-data load (on by default): `python` on `PATH` with
   `pip install -r ../requirements/requirements-setup.txt`. Skip it with
   `-var load_sample_data=false`.

## Usage

### The one-shot path

[`scripts/bootstrap.py`](scripts/bootstrap.py) asks the questions Terraform
cannot, then does everything else:

```powershell
.\infra\bootstrap.ps1          # Windows
```
```bash
./infra/bootstrap.sh           # macOS / Linux
```

It signs you in if needed, asks whether to **create a new service principal or
reuse an existing one**, picks the capacity from the ones you administer, writes
`sp.auto.tfvars` and `terraform.tfvars`, runs `init` / `plan` / `apply`, then
offers to push every variable and secret into GitHub with `gh`. Rehearse the
whole thing first with `--dry-run` — read-only lookups still run, so it resolves
the real principal and lists the real capacities, and prints what it *would*
change instead of guessing.

Useful flags: `--sp-mode {create,existing,skip}`, `--sp-id <appId>`,
`--skip-terraform`, `--skip-github`, `--no-input`. Run it twice and the second
run is a no-op — the whole thing is idempotent.

**The client secret never reaches Terraform.** It is created through `az`, held
in memory, and delivered to GitHub over `gh secret set` stdin. Only the service
principal's *object id* is passed to Terraform, in `sp.auto.tfvars`.

### The manual path

Everything the bootstrap does is still doable by hand. Authentication defaults
to the Azure CLI — no exports, no provider edits, and no config file needed:

```bash
az login --tenant <tenant guid>
az account show          # confirm the right tenant

cd infra
terraform init
terraform plan           # asks for the capacity and the SP object id
terraform apply
```

`capacity` and `dbt_service_principal_object_id` have no default, so Terraform
prompts for them. To answer once instead of on every run, put them in a file:

```bash
cp terraform.tfvars.example terraform.tfvars   # then fill in the two values
```

What the script does that a bare Terraform run cannot: create the service
principal, list your capacities to pick from, and set the GitHub secrets. None
of those are expressible as Terraform input variables.

Note that **`sp.auto.tfvars` wins**: Terraform loads `*.auto.tfvars` after
`terraform.tfvars`, so a stale value there silently overrides the one you just
edited in `terraform.tfvars`.

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

Give `capacity` as a GUID in those runs: a principal that cannot list capacities
cannot resolve a display name either — see *Rough edges* below. Any
non-interactive run also needs `-input=false` plus `-var` or a tfvars file for
both defaultless variables, or Terraform will block waiting on a prompt.

## Wiring the results into GitHub

`bootstrap.py` offers to do this for you, creating the `accept` and `prod`
environments and setting every variable and secret. To do it by hand:

```bash
terraform output -raw gh_commands      # paste-ready gh api/variable/secret lines
terraform output -json ci_variables    # everything, as JSON
terraform output -raw dev_env_file     # the local .env block
```

`gh_commands` creates the environments before it sets any `--env` variable, so
it can be pasted into a fresh repository top to bottom. Only the three
`DBT_SP_*` secret lines are placeholders — Terraform never sees those values.

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

Two variables have **no default**: `capacity` and
`dbt_service_principal_object_id`. Terraform prompts for a variable it cannot
resolve, so running it directly asks for them in the terminal:

```
$ terraform plan

var.capacity
  Fabric capacity hosting every workspace. Either its GUID (Azure Portal >
  the capacity > Properties) or its display name...

  Enter a value:
```

That is the whole point of the missing defaults — a bare `terraform plan` is
usable without editing any file first. `bootstrap.py` writes both values, so the
guided path never sees a prompt, and neither does any subsequent run.

Configuration is split across three files, all gitignored except the template:

| File | Holds | Written by |
| ---- | ----- | ---------- |
| `terraform.tfvars.example` | The committed template. | — |
| `terraform.tfvars` | Capacity and naming. | you, or `bootstrap.py` |
| `sp.auto.tfvars` | `dbt_service_principal_object_id`, nothing else. | `bootstrap.py` |

Terraform loads `*.auto.tfvars` *after* `terraform.tfvars`, so `sp.auto.tfvars`
wins on any variable both set. That is deliberate — the script owns the service
principal id and should not be second-guessed by a stale hand-edit — but it does
mean a value you edit in `terraform.tfvars` and cannot get to take effect is
probably being overridden there.

| Name | Default | Notes |
| ---- | ------- | ----- |
| `tenant_id` | `null` | Optional under CLI auth — `az login --tenant` already pins it. |
| `use_cli` | `true` | Azure CLI auth. The default. |
| `use_oidc` | `false` | GitHub Actions federated credentials. Mutually exclusive with `use_cli`. |
| `client_id` / `client_secret` | `null` | Prefer `FABRIC_CLIENT_ID` / `FABRIC_CLIENT_SECRET`. Never put the secret in a file. |
| `capacity` | **none — prompted** | The capacity's GUID (Azure Portal > the capacity > Properties) or its display name. A GUID is used directly; a name goes through the `fabric_capacity` data source, which also fails the apply if the capacity is paused but needs permission to list capacities. |
| `dbt_service_principal_object_id` | **none — prompted** | The SP's **object** id, not its client id. Blank means no principal, which then requires every `dbt_sp_role` to be `null`. Normally written to `sp.auto.tfvars` by `scripts/bootstrap.py`. |
| `workspace_prefix` | `dbt-accelerator` | Workspace names become `<prefix>-<key>`. |
| `source_lakehouse_name` | `LH_source` | Must equal `DBT_FABRIC_SOURCE_DATABASE`. |
| `code_lakehouse_name` | `LH_dbt_code` | Deployment target for `Files/dbt_project`. |
| `warehouse_collation` | `Latin1_General_100_BIN2_UTF8` | ForceNew. |
| `load_sample_data` | `true` | Load `../sample/*.csv` into every `LH_source`. Needs python + `requirements-setup.txt`. False for real data. |
| `python_command` | `python` | Interpreter for the loader. Point at the venv's python where `python` is not on `PATH`: `"..\\.venv\\Scripts\\python.exe"` on Windows (doubled backslashes — `cmd` reads a leading `../` as a switch), `"../.venv/bin/python"` elsewhere. |
| `environments` | dev/ci/accept/prod | Per-entry: `display_name`, `warehouse_name`, `capacity_id`, `dbt_sp_role`, `deploy_target`. |

## What this does NOT do

- **It does not load anything beyond the demo CSVs.** The sample-data load
  covers the six tables in [`../sample/`](../sample/) and nothing else; real
  source data arrives through whatever pipeline feeds the client's lakehouse.
  With `load_sample_data = false` the lakehouses come out empty, and until the
  source tables exist, CI's `assert_cross_db_access` smoke test still passes —
  it only reads `INFORMATION_SCHEMA` — while `dbt build` fails on missing
  sources.
- **It does not create the capacity**, the GitHub repository, its branches or
  its protection rules. See
  [`../docs/CLIENT_SETUP.md`](../docs/CLIENT_SETUP.md) for the surrounding steps.
- **Terraform does not create the Entra app registration.** That would put a
  live client secret in the state file forever. `scripts/bootstrap.py` creates
  it through `az` instead and hands Terraform only the object id.
- **It does not schedule anything in Fabric.** dev, accept and prod are executed
  by a Fabric-side runtime on its own schedule, configured outside this repo.
  Terraform and the pipelines get the code there; making it run daily is a
  Fabric-side job you set up once per workspace.

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
  Interactive CLI runs by a capacity admin are unaffected. Give `capacity` as a
  GUID and the data source is never instantiated at all.
- **State lives locally, inside OneDrive.** [`versions.tf`](versions.tf) carries
  a commented `backend "azurerm"` block with the `az` commands to create the
  container. Enable it before the first `apply` — OneDrive sync conflicts on a
  state file are unpleasant, and the file holds every connection string.
- **Terraform and the dbt principal must be different identities.** Fabric makes
  the workspace creator an implicit Admin, and a second role assignment for that
  same object id conflicts. So Terraform runs as *you* (`az login`, the `use_cli`
  default) and the dbt SP is only ever a grantee. `bootstrap.py` enforces this:
  it refuses to run under a service-principal login and scrubs
  `FABRIC_CLIENT_ID` / `FABRIC_CLIENT_SECRET` from the environment it hands to
  Terraform. If you deliberately run Terraform *as* the dbt SP, set every
  `dbt_sp_role` to `null` instead — it already has Admin.
- **Destroying is destructive in the obvious way.** `terraform destroy` removes
  workspaces along with every warehouse, lakehouse and table inside them.
