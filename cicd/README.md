# CI/CD Setup

This project ships the same set of pipelines for **GitHub Actions**
(`.github/workflows/` — location mandated by GitHub) and **Azure DevOps**
(`cicd/azure-devops/`). The pipeline names are generic and identical on both
platforms, so you can adopt either without relearning the flow:

| Pipeline        | Trigger                          | What it does                                                        |
| --------------- | -------------------------------- | ------------------------------------------------------------------- |
| `ci`            | pull request                     | lint + parse on every PR; **slim CI build** on the CI workspace for PRs into `dev` |
| `build-dev`     | merge/push to `dev`              | full build on the CI workspace; publishes the manifest used as slim-CI state |
| `deploy-accept` | merge/push to `accept`           | validates (`dbt compile`), then deploys the project **code** to the accept lakehouse (OneLake) |
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
   (slim CI on      (build-dev:        (deploy-accept:       (deploy-prod:
    CI workspace)    CI workspace)      code → lakehouse)     code → lakehouse)
```

Each environment maps to its **own Fabric workspace** (dev / ci / accept / prod).

- Developers branch from `dev` and PR back into `dev`. The `ci` pipeline
  validates the PR (lint, parse, slim CI build on the dedicated Fabric CI
  workspace).
- Once a week, the `promote` pipeline opens two PRs. **Merge order matters**:
  1. Merge `accept -> prod` **first** — prod receives the accept state that has
     been proven stable for a week.
  2. Then merge `dev -> accept` — accept receives the fresh dev state.
- Merging a promotion PR deploys the project **code** to that workspace's
  lakehouse (OneLake). dbt execution on accept/prod happens inside Fabric on
  its own internal schedule — never from the pipelines.

## Slim CI

PRs into `dev` do not rebuild the whole project. The `ci` pipeline downloads
the manifest that `build-dev` published on its last successful run and runs:

```bash
dbt build --target ci --selector ci_modified --state state --defer
```

Only models **modified vs. dev** (plus downstream dependents) are built;
`--defer` resolves unmodified upstream refs to the relations that already exist
in the CI workspace (kept in sync by `build-dev` on every merge to `dev`).
When no state artifact exists yet (first run), it falls back to a full build.

## Required variables (all platforms)

Each environment (ci / accept / prod) has its **own Fabric workspace**, so each
needs its own values for:

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

The pipelines inject the generic names; the profile also accepts per-target
variants (`DBT_FABRIC_HOST_DEV/_CI/_ACCEPT/_PROD`, same for `..._DATABASE`) so a
local `.env` can hold all four workspace connections side by side — the
per-target variable wins when both are set.

## GitHub setup

1. Make `dev` the repository's **default branch** (scheduled workflows such as
   `promote` only run from the default branch).
2. Repo Settings > Actions > General: enable **"Allow GitHub Actions to create
   and approve pull requests"** (needed by `promote`).
3. Repository secrets (used by `ci` and `build-dev` for the CI workspace):
   the five variables above with CI-workspace values.
4. Environments `accept` and `prod` (Settings > Environments), each with its
   own copies of the five secrets. Optionally add required reviewers on `prod`.
5. Branch protection on `dev`, `accept`, `prod` requiring the `ci` checks.

## Azure DevOps setup

1. Variable groups (Pipelines > Library): `dbt-fabric-ci`, `dbt-fabric-accept`,
   `dbt-fabric-prod`, each holding the five variables.
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

No pipeline involvement: copy `profiles.yml.example` to `profiles.yml`, run
`az login`, and use the default `dev` target. All schemas are automatically
prefixed with `dev_<your username>_`, including the seed schemas, so every
developer works fully isolated.
