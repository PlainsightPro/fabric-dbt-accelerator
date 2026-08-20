# CI/CD Setup

This project ships the same set of pipelines for **GitHub Actions**
(`.github/workflows/` — location mandated by GitHub) and **Azure DevOps**
(`cicd/azure-devops/`). The pipeline names are generic and identical on both
platforms, so you can adopt either without relearning the flow:

| Pipeline        | Trigger                          | What it does                                                        |
| --------------- | -------------------------------- | ------------------------------------------------------------------- |
| `ci`            | pull request                     | lint + parse on every PR; **slim CI build** into an isolated `pr_<PR number>` schema for PRs into `dev`, deferring unmodified refs to the dev baseline in the CI warehouse |
| `ci-cleanup`    | PR closed (GitHub) / manual + weekly sweep (ADO) | drops the `pr_<PR number>` schema(s) on the CI warehouse |
| `build-dev`     | merge/push to `dev`              | full `dbt build` into the CI warehouse's layer schemas; publishes that run's manifest as the slim-CI **selection + defer** state |
| `deploy-dev`    | merge/push to `dev`              | validates (`dbt compile --target dev_scheduled`), deploys the project **code** to the dev lakehouse (OneLake) so the Fabric runtime can run it on a schedule |
| `deploy-accept` | merge/push to `accept`           | validates (`dbt compile`), deploys the project **code** to the accept lakehouse (OneLake) |
| `deploy-prod`   | merge/push to `prod`             | validates (`dbt compile`), then deploys the project **code** to the prod lakehouse (OneLake) |
| `promote`       | weekly schedule (Mon 06:00 UTC)  | opens the two promotion PRs (`accept -> prod`, `dev -> accept`)     |

The dbt project lives in [`dbt/`](../dbt/), one level below the repository root.
Every pipeline step that invokes dbt, dbt-bouncer or sqlfluff runs from there —
GitHub Actions via a workflow-level `defaults.run.working-directory`, Azure
DevOps via `workingDirectory: $(dbtDir)` on the individual steps. Steps that
belong to the repo root (installing `requirements/requirements.txt`, calling the
deploy script) deliberately do not.

**No dbt build runs from the pipelines against accept/prod.** The deploy
pipelines ship the project tree to `Files/dbt_project` in the workspace's
lakehouse (via [`scripts/deploy_to_onelake.sh`](scripts/deploy_to_onelake.sh))
and finish by writing an `_EXTRACTED` marker. `PROJECT_DIR` points at `dbt/`, so
what lands in the lakehouse is the dbt project alone — no workflows, docs or
skills. The runtime **inside Fabric**
picks up the deployed project and executes dbt on its own internal schedule.
The marker is the contract: it only appears after every file was uploaded and
the file count was verified against the local tree, so the Fabric runtime never
sees a half-deployed project.

## Branch strategy

```
feature/* ──PR──▶ dev ──weekly PR──▶ accept ──weekly PR──▶ prod
   (slim CI in      (build-dev:        (deploy-accept:       (deploy-prod:
    pr_<N> schema)   full build +       code → lakehouse)     code → lakehouse)
                     manifest)
```

Each environment maps to its **own Fabric workspace** (dev / accept / prod) —
**except the CI warehouse, which must live in the SAME workspace as the
`LH_source` lakehouse**: every CI build reads the sources, and Fabric only
allows cross-database (three-part-name) queries between items in one workspace.
See [`docs/ci_architecture.md`](../docs/ci_architecture.md).

- Developers branch from `dev` and PR back into `dev`. The `ci` pipeline
  validates the PR (lint, parse, slim CI build into the PR's own schema on
  the dedicated Fabric CI warehouse).
- Once a week, the `promote` pipeline opens two PRs. **Merge order matters**:
  1. Merge `accept -> prod` **first** — prod receives the accept state that has
     been proven stable for a week.
  2. Then merge `dev -> accept` — accept receives the fresh dev state.
- Merging a promotion PR deploys the project **code** to that workspace's
  lakehouse (OneLake). dbt execution on accept/prod happens inside Fabric on
  its own internal schedule — never from the pipelines.

## Slim CI

PRs into `dev` do not rebuild the whole project. The `ci` pipeline downloads the
manifest published by `build-dev` and runs:

```bash
dbt build --target ci --selector ci_modified --state state_dev --defer --favor-state
```

That one manifest serves both roles:

- **selection** (`--state`) — which nodes count as modified vs. the `dev` branch;
- **defer** (`--defer-state`, which defaults to `--state`) — unmodified upstream
  refs resolve to the relations `build-dev` materialized in the CI warehouse's
  layer schemas (`<CI_DB>.bronze_sales|silver|gold.<table>`).

`--favor-state` makes that resolution unconditional. By default dbt would prefer
a relation of the same name left in `pr_<N>` by an earlier push of the same PR,
mixing two build epochs and failing the gold `relationships` tests with orphans
that do not reproduce on `dev`. See
[`docs/ci_architecture.md`](../docs/ci_architecture.md).

The two roles may share a manifest **only because `build-dev` runs a real
`dbt build`**: defer needs a description of relations that exist, not of code.
That is also why nothing defers to `accept` — the accept warehouse is
materialized by the Fabric runtime on its own schedule, so no pipeline can
publish a manifest guaranteed to match it.

Modified models (+ downstream dependents) are built into the PR's isolated
`pr_<PR number>` schema on the CI warehouse (`generate_schema_name`, driven by
`DBT_CI_SCHEMA_SUFFIX`), and `ci-cleanup` drops that schema when the PR closes.
Because PRs write only to `pr_<N>`, the baseline they defer to is never mutated
by another PR. A smoke test at the start of the job verifies cross-database
access to the source lakehouse and fails fast with a colocation hint otherwise.
When the manifest is missing (first run), the pipeline falls back to a full
build — still isolated in the PR schema. Details and failure modes:
[`docs/ci_architecture.md`](../docs/ci_architecture.md).

## Required variables (all platforms)

Each environment (dev / ci / accept / prod) has its **own warehouse** (the CI
warehouse colocated with the source lakehouse, see above), so each needs its own
values for:

| Variable                     | Description                              |
| ---------------------------- | ---------------------------------------- |
| `DBT_FABRIC_HOST`            | Fabric warehouse SQL endpoint            |
| `DBT_FABRIC_DATABASE`        | Fabric warehouse name                    |
| `DBT_FABRIC_SOURCE_DATABASE` | Lakehouse holding the raw source tables, read by the `_sources.yml` files under `models/bronze/staging/` |
| `DBT_SP_TENANT_ID`           | Entra ID tenant id                       |
| `DBT_SP_CLIENT_ID`           | Service principal application id         |
| `DBT_SP_CLIENT_SECRET`       | Service principal secret (**store as secret**) |

`DBT_FABRIC_SOURCE_DATABASE` is **required and has no default**: the sources
declare it as a bare `env_var()`, so an unset variable fails at parse time
rather than silently pointing at the wrong lakehouse.

Platform note: **GitHub Actions** does not export repository variables to steps
automatically, so the workflows map this one explicitly (`ci` and `build-dev`
read `DBT_FABRIC_SOURCE_DATABASE_CI`; the deploy workflows read the
environment-scoped `DBT_FABRIC_SOURCE_DATABASE`). Because GitHub turns an
*undefined* variable into an empty string rather than leaving it absent — which
would slip past dbt's own check — each workflow guards it with an explicit
non-empty test before the first dbt command. **Azure DevOps** exposes every
non-secret variable-group value to script steps as an environment variable, so
adding `DBT_FABRIC_SOURCE_DATABASE` to the relevant variable group is enough,
and an undefined one is genuinely absent, so dbt's own error is clear.

Accept and prod additionally need the OneLake deployment target:

| Variable                 | Description                                        |
| ------------------------ | -------------------------------------------------- |
| `DBT_FABRIC_WORKSPACE`   | workspace segment of the OneLake URL (name or GUID) |
| `DBT_FABRIC_DATALAKE_ID` | lakehouse item GUID under which `Files/dbt_project` lives |

The service principal needs access to the ci, accept, **and** prod workspaces
(e.g. workspace Contributor, or granular warehouse permissions).

**The `ci` target has no fallback**: `profiles.yml`'s `ci` output reads
`DBT_FABRIC_HOST_CI`/`DBT_FABRIC_DATABASE_CI` only - both platforms' `ci`,
`ci-cleanup`, and `build-dev` pipelines must inject those exact suffixed names,
not the generic ones. `accept`/`prod` are more forgiving: their outputs fall
back to the generic `DBT_FABRIC_HOST`/`DBT_FABRIC_DATABASE` if the
`_ACCEPT`/`_PROD`-suffixed variants aren't set, which is what the pipelines
below rely on. `dev` works the same way (falls back from `DBT_FABRIC_HOST_DEV`),
which is why a local `.env` can hold all four workspace connections side by
side under their per-target names - the per-target variable always wins when
both are set.

## Contributing from a fork

**PRs opened from a fork cannot be validated.** Branch inside this repository and
open the PR from there.

Every check in the `ci` pipeline needs a live connection to the Fabric CI
warehouse — including linting, because [`dbt/.sqlfluff-ci`](../dbt/.sqlfluff-ci)
sets `target = ci` and the incremental `silver/ads/` models call
`is_incremental()`, which resolves `adapter.get_relation()` against the
warehouse. That connection authenticates with the service principal, and both
platforms deliberately keep those credentials away from forks:

- **GitHub Actions** never passes `secrets.*` to a `pull_request` run whose head
  repo is a fork. Repository *variables* still arrive, so a fork run sees a
  perfectly good host and database name alongside empty credentials.
- **Azure DevOps** withholds secret variables from builds of forks unless
  *"Make secrets available to builds of forks"* is enabled on the pipeline (off
  by default).

This is the right default: a PR can change any model SQL, and on GitHub the
workflow file itself, so handing it the service principal would let unreviewed
code read and write the CI warehouse.

Left unguarded, the failure is thoroughly misleading. `profiles.yml`'s `ci`
output reads the credentials as bare `env_var()` calls with **no default**, and
both platforms supply an unavailable secret as an *empty string* rather than
leaving it absent — so dbt's own "Env var required but not provided" error never
fires. Auth fails silently, the connection handle stays null, and dbt-fabric
raises `'NoneType' object has no attribute 'cursor'`, which sqlfluff then reports
as a `TMP` violation against whichever model it happened to be compiling:

```
== [models/bronze/staging/hr/stg_hr__sales_reps.sql] FAIL
L: 0 | P: 0 | TMP | Error received from dbt during project compilation.
                  | DbtRuntimeError: 'NoneType' object has no attribute 'cursor'
```

The named model is innocent — it is just the first file in the walk. Both `ci`
pipelines therefore run a **Check Fabric CI credentials are available** guard
immediately after checkout, before the ODBC and pip installs, which fails in
seconds and distinguishes the two causes: a fork PR, or a genuinely missing
variable/secret. If the guard passes and the connection still fails, the
credentials are present but the principal cannot reach the warehouse. Two
causes, in order of likelihood:

1. **The service principal has no role on the CI workspace.** Recreating the
   workspace destroys its role assignments, and Terraform only recreates them
   when `dbt_service_principal_object_id` and `dbt_sp_role` are set in
   `terraform.tfvars`. Check:
   ```bash
   az rest --method get --resource https://api.fabric.microsoft.com \
     --url https://api.fabric.microsoft.com/v1/workspaces/<workspace id>/roleAssignments
   ```
2. **An expired service principal secret** — `az ad app credential list --id <appId>`.

Reproduce either locally, where the real ODBC error is visible instead of the
`NoneType` mask, by exporting the same variables the pipeline sets and running
`dbt debug --target ci` from `dbt/`. Note that `VAR=value` without `export`
sets a shell variable the `dbt` child process never sees.

Maintainers configuring these credentials: see **Required variables** above plus
the platform setup section below.

## GitHub setup

1. Make `dev` the repository's **default branch** (scheduled workflows such as
   `promote` only run from the default branch).
2. Repo Settings > Actions > General: enable **"Allow GitHub Actions to create
   and approve pull requests"** (needed by `promote`).
3. Repository variables `DBT_FABRIC_HOST_CI` / `DBT_FABRIC_DATABASE_CI` and
   repository secrets `DBT_SP_TENANT_ID` / `DBT_SP_CLIENT_ID` /
   `DBT_SP_CLIENT_SECRET` (used by `ci`, `ci-cleanup`, and `build-dev` for the
   CI warehouse).
4. Environments `accept` and `prod` (Settings > Environments), each with its
   own copies of the five secrets. Optionally add required reviewers on `prod`.
5. Branch protection on `dev`, `accept`, `prod` requiring the `ci` checks.

## Azure DevOps setup

1. Variable groups (Pipelines > Library): `dbt-fabric-ci`, `dbt-fabric-accept`,
   `dbt-fabric-prod`. `dbt-fabric-ci` must use the suffixed names
   `DBT_FABRIC_HOST_CI`/`DBT_FABRIC_DATABASE_CI` (plus the three `DBT_SP_*`
   variables) - `accept`/`prod` can use the unsuffixed names since their
   targets fall back to them.
2. Create one pipeline per YAML file in `cicd/azure-devops/`.
3. Put the definition ID of the `build-dev` pipeline into `devBuildPipelineId`
   in `cicd/azure-devops/ci.yml` so slim CI can download the state artifact.
4. Azure Repos: add the `ci` pipeline as a build-validation branch policy on
   `dev` (and optionally `accept`/`prod`).
5. `promote` requires the Build Service identity to have "Contribute" and
   "Contribute to pull requests" permissions on the repo. It only applies when
   the code is hosted in Azure Repos — for GitHub-hosted code use
   `.github/workflows/promote.yml`.
6. Optional: Environment `prod` (Pipelines > Environments) with approval
   checks — `deploy-prod` binds to it.

## Local development

No pipeline involvement: `profiles.yml` is committed and already configured for
all four targets, so just set `DBT_FABRIC_HOST`/`DBT_FABRIC_DATABASE`, run
`az login`, and use the default `dev` target. All schemas are automatically
prefixed with `dev_<your username>_`, including the seed schemas, so every
developer works fully isolated.
