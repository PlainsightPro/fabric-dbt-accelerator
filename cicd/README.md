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
| `deploy-accept` | merge/push to `accept`           | validates (`dbt compile`), deploys the project **code** to the accept lakehouse (OneLake) |
| `deploy-prod`   | merge/push to `prod`             | validates (`dbt compile`), then deploys the project **code** to the prod lakehouse (OneLake) |
| `promote`       | weekly schedule (Mon 06:00 UTC)  | opens the two promotion PRs (`accept -> prod`, `dev -> accept`)     |

**No dbt build runs from the pipelines against accept/prod.** The deploy
pipelines ship the project tree to `Files/dbt_project` in the workspace's
lakehouse (via [`scripts/deploy_to_onelake.sh`](scripts/deploy_to_onelake.sh))
and finish by writing an `_EXTRACTED` marker. The runtime **inside Fabric**
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
dbt build --target ci --selector ci_modified --state state_dev --defer
```

That one manifest serves both roles:

- **selection** (`--state`) — which nodes count as modified vs. the `dev` branch;
- **defer** (`--defer-state`, which defaults to `--state`) — unmodified upstream
  refs resolve to the relations `build-dev` materialized in the CI warehouse's
  layer schemas (`<CI_DB>.bronze_sales|silver|gold.<table>`).

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

Each environment (ci / accept / prod) has its **own warehouse** (the CI
warehouse colocated with the source lakehouse, see above), so each needs its own
values for:

| Variable                 | Description                              |
| ------------------------ | ---------------------------------------- |
| `DBT_FABRIC_HOST`        | Fabric warehouse SQL endpoint            |
| `DBT_FABRIC_DATABASE`    | Fabric warehouse name                    |
| `DBT_SP_TENANT_ID`       | Entra ID tenant id                       |
| `DBT_SP_CLIENT_ID`       | Service principal application id         |
| `DBT_SP_CLIENT_SECRET`   | Service principal secret (**store as secret**) |

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
