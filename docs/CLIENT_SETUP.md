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
  require Global Admin. Step 3 can instead reuse an app someone else created,
  in which case you only need its client id.
- **Fabric admin portal access** (or someone who has it) for one tenant
  setting in step 1.
- **Capacity administrator** rights on the existing Fabric capacity (or
  someone who can add an admin to it) - see step 1.
- Local tooling: [Terraform](https://developer.hashicorp.com/terraform/install)
  >= 1.9, [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli),
  Python 3.11, and `git`. Optionally the
  [GitHub CLI](https://cli.github.com/) (`gh`), which lets step 3 wire the
  repository up for you.

## Step 1: One-time Fabric prep

These two things live in portals rather than APIs, so no script can do them.
Both fail late and confusingly when missed - do them first.

1. **Enable service principal access to the Fabric API.** Fabric Admin Portal
   ([app.fabric.microsoft.com](https://app.fabric.microsoft.com) > Settings >
   Admin portal > Tenant settings) > "Developer settings" > **"Service
   principals can use Fabric APIs"** - turn this **On** (scope it to a
   security group containing the SP created in step 3, or tenant-wide for
   simplicity). Without this, every Fabric API call the SP makes fails with an
   authorization error, no matter how many Fabric roles it holds.
2. **Make yourself a capacity administrator** on the existing Fabric capacity:
   Azure Portal > the capacity resource > "Capacity administrators". Assigning
   new workspaces to a capacity needs this, and being an Azure subscription
   Owner does **not** cover it - the capacity admin list is separate, and a
   capacity you are not an admin on is invisible to Terraform's lookup.

The service principal itself is created in step 3; you do not need to make one
by hand.

## Step 2: Get the code into the client's GitHub

Fork this repo (or push a copy) into the client's GitHub account/org. Do not
carry over your own `.env` (gitignored, shouldn't exist in the repo) or any
`terraform.tfvars` (also gitignored) - both hold secrets specific to whoever
ran them last.

## Step 3: Provision Fabric workspaces with Terraform (`infra/`)

`infra/` provisions four independent workspaces (dev/ci/accept/prod), each with
its own warehouse and a source lakehouse, plus a code lakehouse on the deploy
targets — dev, accept and prod. Full reference:
[`infra/README.md`](../infra/README.md).

CI gets its own workspace for two reasons. Fabric only allows cross-database
queries **within** one workspace, so the CI warehouse has to sit beside the
`LH_source` lakehouse it reads; and `build-dev` runs a full
`dbt build --target ci` on every merge to `dev` to maintain the slim-CI defer
baseline, rewriting the `bronze_sales` / `silver` / `gold` schemas wholesale.
That must never land in a workspace anyone reads. (PR builds stay confined to
their `pr_<N>` schema — `build-dev` deliberately does not.)

```bash
# The apply ends by loading the demo CSVs into each source lakehouse, which
# needs a few Python packages. Skip this only if you set load_sample_data =
# false below.
python -m venv .venv && source .venv/bin/activate  # Windows: .venv\Scripts\Activate.ps1
pip install -r requirements/requirements-setup.txt

az login --tenant <tenant guid>

./infra/bootstrap.sh          # Windows: .\infra\bootstrap.ps1
```

That one command does the rest. It asks whether to **create a new service
principal or use an existing one**, picks the capacity from the ones you
administer, applies `infra/`, and offers to push every variable and secret into
GitHub (step 4 below). Rehearse it first with `--dry-run`.

Expect `21 to add`: 4 workspaces, 4 warehouses, 6 lakehouses, 3 role assignments
and 4 sample-data loads.

**Two identities, not one.** Terraform runs as *you* over `az login`; the
service principal it creates is only ever a grantee, receiving `Contributor` on
the ci, accept and prod workspaces. That separation matters: Fabric makes the
workspace creator an implicit Admin, and a second role assignment for that same
principal conflicts. The bootstrap enforces it by refusing to run under a
service-principal login.

**The client secret never reaches Terraform state.** It is created through `az`,
held in memory for the run, and delivered to GitHub over `gh secret set` stdin.
Only the SP's object id goes to Terraform, in `infra/sp.auto.tfvars`.

<details>
<summary>Doing it by hand instead</summary>

Create the principal:

```bash
az ad app create --display-name sp-dbt-accelerator --sign-in-audience AzureADMyOrg
az ad sp create --id <appId>
az ad app credential reset --id <appId> --years 1 --append
az ad sp show --id <appId> --query id -o tsv    # the OBJECT id, not the appId
```

`az ad sp create-for-rbac` also works but additionally grants an Azure RBAC role
on the subscription that this principal has no use for — Fabric workspace roles
are a separate system.

Then apply. `capacity` and `dbt_service_principal_object_id` have no default, so
Terraform asks for both in the terminal — no config file is required:

```bash
cd infra
terraform init
terraform plan     # var.capacity: <capacity GUID or display name>
                   # var.dbt_service_principal_object_id: <the OBJECT id above>
terraform apply
```

To answer once instead of on every run, put them in `terraform.tfvars`
(gitignored) — `cp terraform.tfvars.example terraform.tfvars` and fill in the
two values at the top.

</details>

The four `terraform_data.sample_data` resources run last and print the tables
they write. If they fail because `python` is not the venv's interpreter, pass
`-var python_command=../.venv/Scripts/python.exe` — the Fabric items are
already created at that point, so a re-apply retries only the load.

## Step 4: Wire Terraform outputs into GitHub

**`bootstrap.sh` already offered to do this.** Run `gh auth login` before it and
answer yes, and this step is done — including the `DBT_SP_*` secrets, which it
is the only thing that can set without you copying a credential around.

To do it separately, or to re-run it later:

```bash
gh auth login
terraform -chdir=infra output -raw gh_commands
```

That prints ready-to-run `gh api` / `gh variable set` / `gh secret set` lines for
every value below, creating the `accept` and `prod` environments first so the
block can be pasted top to bottom. Review them, fill in the three secret
placeholders, and run them. To do it by hand in the GitHub UI instead, use
`terraform -chdir=infra output -json ci_variables` and:

1. **Settings > Secrets and variables > Actions > Variables** (repository
   level): `DBT_FABRIC_HOST_CI`, `DBT_FABRIC_DATABASE_CI` and
   `DBT_FABRIC_SOURCE_DATABASE_CI`, all from the **ci** environment's block.
2. **Settings > Secrets and variables > Actions > Secrets** (repository
   level): `DBT_SP_TENANT_ID`, `DBT_SP_CLIENT_ID`, `DBT_SP_CLIENT_SECRET`
   (the same SP from step 3). These are not Terraform outputs on purpose — a
   client secret in a variable would sit in the state file in plaintext.
3. **Settings > Environments**: create `accept` and `prod`. In each, add the
   variables `DBT_FABRIC_HOST`, `DBT_FABRIC_DATABASE`,
   `DBT_FABRIC_SOURCE_DATABASE`, `DBT_FABRIC_WORKSPACE` and
   `DBT_FABRIC_DATALAKE_ID` from that environment's block. Repository secrets
   are readable from environment-scoped jobs, so the SP secrets need not be
   repeated. Optionally add required reviewers on `prod` so deploys need human
   approval.

> ℹ️ **The lakehouses come pre-loaded with demo data.** With the default
> `load_sample_data = true`, `terraform apply` writes the six CSVs in
> [`sample/`](../sample/) into every `LH_source` as Delta tables under
> `raw_sales`, `raw_hr` and `mdm`, so `dbt build` works immediately.
>
> For a client environment carrying real data, set `load_sample_data = false`
> in `terraform.tfvars` — the lakehouses then come out empty, and until the
> source tables exist, CI's cross-database smoke test still passes (it only
> reads `INFORMATION_SCHEMA`) while `dbt build` fails on missing sources.

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

The source lakehouse is already populated from [`sample/`](../sample/) unless
you set `load_sample_data = false`; in that case, load the raw tables to match
the `_sources.yml` files under `dbt/models/bronze/staging/*/` and
[`docs/WORKBOOK_CONNECT.md`](WORKBOOK_CONNECT.md) first. Then:

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
