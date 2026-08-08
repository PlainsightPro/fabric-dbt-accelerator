# Client setup guide

Step-by-step setup of this accelerator for a client who starts with **only**:

- An existing **Microsoft Fabric capacity** (already provisioned in their Azure tenant).
- A **GitHub account/org** to host the repo.

Nothing else is assumed - no existing Fabric workspaces, no service principal,
no Azure DevOps. This guide is GitHub-only (`.github/workflows/`); ignore
`cicd/azure-devops/` unless the client later moves to Azure DevOps.

## What you'll need to acquire along the way

Having a Fabric capacity implies an Azure/Entra tenant already exists. You will
additionally need:

- **Permission to create an Entra app registration** (service principal) in
  that tenant - typically "Application Administrator" or similar; doesn't
  require Global Admin.
- **Fabric admin portal access** (or someone who has it) for one tenant
  setting in step 1.
- **Capacity administrator** rights on the existing Fabric capacity (or
  someone who can add an admin to it) - see step 1.
- Local tooling: [Terraform](https://developer.hashicorp.com/terraform/install)
  >= 1.8, [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli),
  Python 3.11, and `git`.

## Step 1: One-time Fabric/Entra prep

These two things trip up almost every first setup - do them before touching
Terraform.

1. **Enable service principal access to the Fabric API.** Fabric Admin Portal
   ([app.fabric.microsoft.com](https://app.fabric.microsoft.com) > Settings >
   Admin portal > Tenant settings) > "Developer settings" > **"Service
   principals can use Fabric APIs"** - turn this **On** (scope it to a
   security group containing the SP you create in step 2, or tenant-wide for
   simplicity). Without this, every Terraform/API call the SP makes fails
   with an authorization error, no matter how many Fabric roles it holds.
2. **Create the service principal.**
   ```bash
   az login
   az ad sp create-for-rbac --name "sp-dbt-accelerator" --skip-assignment
   ```
   Note the `appId` (client ID), `password` (client secret - shown once), and
   `tenant` from the output. Also fetch the SP's **object ID** (different
   from the client ID, needed later):
   ```bash
   az ad sp show --id <appId> --query id -o tsv
   ```
3. **Add the SP as an administrator on the existing Fabric capacity**: Azure
   Portal > the capacity resource > "Capacity administrators" > add the SP.
   Terraform's capacity lookup only needs step 1, but *assigning* new
   workspaces to the capacity needs this.

## Step 2: Get the code into the client's GitHub

Fork this repo (or push a copy) into the client's GitHub account/org. Do not
carry over your own `.env` (gitignored, shouldn't exist in the repo) or any
`terraform.tfvars` (also gitignored) - both hold secrets specific to whoever
ran them last.

## Step 3: Provision Fabric workspaces with Terraform (`infra/`)

`infra/` provisions four independent workspaces (dev/ci/accept/prod), each with
its own warehouse and a source lakehouse, plus a code lakehouse on accept and
prod. Full reference: [`infra/README.md`](../infra/README.md).

CI gets its own workspace for two reasons. Fabric only allows cross-database
queries **within** one workspace, so the CI warehouse has to sit beside the
`LH_source` lakehouse it reads; and `build-dev` runs a full
`dbt build --target ci` on every merge to `dev` to maintain the slim-CI defer
baseline, rewriting the `bronze_sales` / `silver` / `gold` schemas wholesale.
That must never land in a workspace anyone reads. (PR builds stay confined to
their `pr_<N>` schema — `build-dev` deliberately does not.)

```bash
cd infra
export FABRIC_TENANT_ID=<tenant>
export FABRIC_CLIENT_ID=<appId>
export FABRIC_CLIENT_SECRET=<password>
terraform init
```

Create `infra/terraform.tfvars` from the committed template (both gitignored):

```hcl
# Azure Portal > your Fabric capacity > Properties
capacity_id = "<capacity GUID>"

# The OBJECT id from step 1.2 - not the appId.
dbt_service_principal_object_id = "<object ID>"

workspace_prefix = "dbt-accelerator"
```

That is the whole configuration: the `environments` variable already defaults to
dev/ci/accept/prod wired the way the pipelines expect.

> **If the dbt service principal is the same app that runs Terraform** — which
> is what step 1 sets up — omit `dbt_service_principal_object_id` and set every
> `dbt_sp_role` to `null` in an `environments` override. Terraform's principal
> is already workspace Admin as the creator, and a second role assignment for
> the same principal conflicts.

```bash
terraform plan     # expect 4 workspaces, 4 warehouses, 6 lakehouses
terraform apply
```

## Step 4: Wire Terraform outputs into GitHub

The fastest path — `gh auth login` first, then run from the repo root:

```bash
terraform -chdir=infra output -raw gh_commands
```

That prints ready-to-run `gh variable set` / `gh secret set` lines for every
value below. Review them, fill in the three secret placeholders, and run them.
To do it by hand in the GitHub UI instead, use
`terraform -chdir=infra output -json ci_variables` and:

1. **Settings > Secrets and variables > Actions > Variables** (repository
   level): `DBT_FABRIC_HOST_CI`, `DBT_FABRIC_DATABASE_CI` and
   `DBT_FABRIC_SOURCE_DATABASE_CI`, all from the **ci** environment's block.
2. **Settings > Secrets and variables > Actions > Secrets** (repository
   level): `DBT_SP_TENANT_ID`, `DBT_SP_CLIENT_ID`, `DBT_SP_CLIENT_SECRET`
   (the same SP from step 1). These are not Terraform outputs on purpose — a
   client secret in a variable would sit in the state file in plaintext.
3. **Settings > Environments**: create `accept` and `prod`. In each, add the
   variables `DBT_FABRIC_HOST`, `DBT_FABRIC_DATABASE`,
   `DBT_FABRIC_SOURCE_DATABASE`, `DBT_FABRIC_WORKSPACE` and
   `DBT_FABRIC_DATALAKE_ID` from that environment's block. Repository secrets
   are readable from environment-scoped jobs, so the SP secrets need not be
   repeated. Optionally add required reviewers on `prod` so deploys need human
   approval.

> ⚠️ **The lakehouses are empty after `terraform apply`.** The `raw_sales`,
> `raw_hr` and `mdm` schemas and their tables are data, not infrastructure.
> Until they are loaded, CI's cross-database smoke test still passes — it only
> reads `INFORMATION_SCHEMA` — while `dbt build` fails on missing sources.

## Step 5: GitHub repository settings

1. **Settings > General > Default branch**: set to `dev` (the `promote`
   workflow's weekly schedule only runs from the default branch).
2. **Settings > Actions > General**: enable "Allow GitHub Actions to create
   and approve pull requests" (needed by `promote`).
3. Create the `accept` and `prod` branches from `dev` if they don't exist yet
   (`git checkout -b accept && git push -u origin accept`, same for `prod`).
4. **Settings > Branches**: add protection rules on `dev`/`accept`/`prod`
   requiring the `ci` status check before merging.

## Step 6: Local developer environment

Same as [`docs/ONBOARDING.md`](ONBOARDING.md):

```bash
git clone <repo>
python -m venv .venv && source .venv/bin/activate  # or .venv\Scripts\Activate.ps1
pip install -r requirements/requirements.txt

# The dbt project lives one level down; every dbt command runs from there.
cd dbt
dbt deps
az login
dbt debug --profiles-dir .
```

Write the `.env` for the dev target straight from Terraform — it emits the
whole block, including the `_CI` variables needed to run `--target ci` locally:

```bash
terraform -chdir=infra output -raw dev_env_file > .env
```

There's no seed data step by default in this accelerator's current state -
populate the source lakehouse per
[`docs/WORKBOOK_CONNECT.md`](WORKBOOK_CONNECT.md) and the `_sources.yml` files
under `dbt/models/bronze/staging/*/`, then:

```bash
dbt build --profiles-dir .
dbt docs generate --profiles-dir .
```

## Step 7: First end-to-end verification

1. Open a throwaway PR from a feature branch into `dev` - confirms `ci`
   (lint, parse, `dbt-bouncer`, slim CI build, `dbt docs generate`) runs
   green. Watch for the cross-database smoke test specifically; if it fails,
   `DBT_FABRIC_HOST_CI` and `DBT_FABRIC_SOURCE_DATABASE_CI` are pointing at
   items in different workspaces. You can reproduce it locally without CI:
   `cd dbt && dbt run-operation assert_cross_db_access --args '{database: LH_source}' --target ci`.
2. Merge that PR into `dev` - confirms `build-dev` runs.
3. Manually trigger `promote` (workflow_dispatch) or wait for its Monday
   schedule, then merge the two PRs it opens (`accept -> prod` first, then
   `dev -> accept`) - confirms `deploy-accept`/`deploy-prod` upload the
   project to OneLake and the Fabric-internal schedule can pick it up.

## Reference

- [`cicd/README.md`](../cicd/README.md) - full pipeline reference, required
  variables table.
- [`docs/ci_architecture.md`](ci_architecture.md) - why slim CI needs the
  colocation this guide arranges for.
- [`infra/README.md`](../infra/README.md) - Terraform variable reference, what
  the module deliberately does not do, known rough edges (SQL endpoint
  provisioning lag, ForceNew settings).
- [`docs/ONBOARDING.md`](ONBOARDING.md) - day-to-day developer workflow once
  setup is done.
