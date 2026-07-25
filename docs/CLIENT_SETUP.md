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

The default `infra/` config provisions 4 **independent** workspaces
(dev/ci/accept/prod). With a single capacity and a client rollout, we
recommend provisioning **3 workspaces** instead and pointing `ci` at the same
warehouse as `accept` - see the callout below for why.

```bash
cd infra
export FABRIC_TENANT_ID=<tenant>
export FABRIC_CLIENT_ID=<appId>
export FABRIC_CLIENT_SECRET=<password>
export ARM_TENANT_ID=<tenant>
export ARM_CLIENT_ID=<appId>
export ARM_CLIENT_SECRET=<password>
export ARM_SUBSCRIPTION_ID=<subscription that hosts the Fabric capacity>
terraform init
```

Create `infra/terraform.tfvars` (gitignored):

```hcl
dbt_service_principal_object_id = "<object ID from step 1.2>"

environments = {
  dev = {
    display_name    = "dbt-accelerator-dev"
    capacity_source = "existing"
    capacity_key    = "<exact display name of the client's Fabric capacity>"
    dbt_sp_role     = null # dev is human/CLI-auth only
  }
  accept = {
    display_name    = "dbt-accelerator-accept"
    capacity_source = "existing"
    capacity_key    = "<same capacity display name>"
    dbt_sp_role     = "Contributor"
  }
  prod = {
    display_name    = "dbt-accelerator-prod"
    capacity_source = "existing"
    capacity_key    = "<same capacity display name>"
    dbt_sp_role     = "Contributor"
  }
}
```

Note this has **3** entries, not 4 - `ci` is deliberately omitted (see below).
`new_capacities` stays at its default `{}` since you're reusing the existing
capacity for all three; the `azurerm` provider still needs working credentials
to start even though it creates nothing.

```bash
terraform plan
terraform apply
terraform output -json ci_variables > ../ci_variables.json   # keep this, step 4 needs it
```

> ⚠️ **Why `ci` is omitted, and what this means**
>
> `docs/ci_architecture.md` requires the `ci` warehouse and `accept` warehouse
> to live in the **same Fabric workspace**, because slim CI's PR builds defer
> unmodified refs to the accept warehouse via a cross-database query, and
> Fabric only allows that within one workspace. The `infra/` module creates
> one workspace per environment key - it has no way to put `ci` and `accept`
> in the same workspace. Two ways to resolve this:
>
> - **(Recommended for a client rollout, done above)**: skip provisioning a
>   separate `ci` workspace/warehouse entirely. Point the pipeline's CI
>   variables at the **same warehouse as `accept`** (step 4). PR builds land
>   in their own `pr_<N>` schema on that warehouse, isolated from the shared
>   `ads`/`gold` schemas by schema name alone - the same isolation mechanism
>   already used between concurrent PRs today. Simpler, cheaper (3 workspaces
>   instead of 4), and it satisfies the colocation requirement trivially
>   since there's no cross-*workspace* query at all anymore.
> - **(Not automated here)**: add a 4th `ci` environment back to
>   `terraform.tfvars` and manually add a second warehouse inside the
>   `accept` workspace afterwards (outside Terraform, or by extending
>   `infra/warehouses.tf` to support multiple warehouses per environment -
>   not built today). Only worth it if the client needs CI compute fully
>   isolated from the accept warehouse's usage.

## Step 4: Wire Terraform outputs into GitHub

Open `ci_variables.json` from step 3. For each environment it has
`DBT_FABRIC_HOST`, `DBT_FABRIC_DATABASE`, `DBT_FABRIC_WORKSPACE`,
`DBT_FABRIC_DATALAKE_ID`.

In the GitHub repo (Settings):

1. **Settings > Secrets and variables > Actions > Variables** (repository
   level): add `DBT_FABRIC_HOST_CI` and `DBT_FABRIC_DATABASE_CI`, both set to
   `ci_variables.accept.DBT_FABRIC_HOST` / `.DBT_FABRIC_DATABASE` (same
   warehouse as accept - see step 3's callout).
2. **Settings > Secrets and variables > Actions > Secrets** (repository
   level): add `DBT_SP_TENANT_ID`, `DBT_SP_CLIENT_ID`, `DBT_SP_CLIENT_SECRET`
   (the same SP from step 1).
3. **Settings > Environments**: create `accept` and `prod`. In each, add
   variables `DBT_FABRIC_HOST`, `DBT_FABRIC_DATABASE`, `DBT_FABRIC_WORKSPACE`,
   `DBT_FABRIC_DATALAKE_ID` from that environment's block in
   `ci_variables.json`, and secrets `DBT_SP_TENANT_ID` / `DBT_SP_CLIENT_ID` /
   `DBT_SP_CLIENT_SECRET` (same SP again). Optionally add required reviewers
   on `prod` so deploys need human approval.

Delete `ci_variables.json` locally once done - it has no secrets in it
(hosts/IDs only) but there's no reason to keep it lying around.

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
pip install -r requirements/requirements_fabric.txt
dbt deps
export DBT_FABRIC_HOST=<dev workspace warehouse SQL endpoint>      # from terraform output workspace_id / warehouse_host
export DBT_FABRIC_DATABASE=<dev workspace warehouse name>
az login
dbt debug --profiles-dir .
```

`dev`'s warehouse host/name come from `terraform output warehouse_host` /
`warehouse_name` (the `dev` key) back in `infra/`. There's no seed data step
by default in this accelerator's current state - populate the source
lakehouse per [`docs/WORKBOOK_CONNECT.md`](WORKBOOK_CONNECT.md) and the
`_sources.yml` files under `models/bronze/staging/*/`, then:

```bash
dbt build --profiles-dir .
dbt docs generate --profiles-dir .
```

## Step 7: First end-to-end verification

1. Open a throwaway PR from a feature branch into `dev` - confirms `ci`
   (lint, parse, `dbt-bouncer`, slim CI build, `dbt docs generate`) runs
   green. Watch for the cross-database smoke test specifically; if it fails,
   double check step 4.1 actually points `DBT_FABRIC_HOST_CI` at the
   **accept** warehouse, not a nonexistent separate one.
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
- [`infra/README.md`](../infra/README.md) - Terraform variable reference,
  capacity mix options, known rough edges (ARM/Fabric propagation lag, etc).
- [`docs/ONBOARDING.md`](ONBOARDING.md) - day-to-day developer workflow once
  setup is done.
