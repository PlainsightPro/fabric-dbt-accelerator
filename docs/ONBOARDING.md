# Onboarding guide

## Branch strategy

- Create your feature branch from `dev` and open your PR back into `dev`
  (slim CI builds your changes into an isolated `pr_<PR number>` schema on the
  Fabric CI warehouse, deferring unmodified refs to the dev baseline that
  `build-dev` maintains there — see [`ci_architecture.md`](ci_architecture.md)).
- `accept` and `prod` receive code only through the weekly promotion PRs
  (`dev -> accept`, `accept -> prod`) — never push to them directly.

## Developer workflow

1. Clone the repository.
2. Create a Python virtual environment.
3. Install dependencies from `requirements/requirements.txt`.
4. `profiles.yml` is committed to the repo, already configured for all four
   targets - set `DBT_FABRIC_HOST` / `DBT_FABRIC_DATABASE` (or edit the dev
   defaults) rather than copying or editing a per-developer file. Your schemas
   are automatically prefixed with `dev_<your username>_` — models and seeds
   alike — so you work in a fully isolated environment.
5. Run `az login` (the `dev` target uses Azure CLI auth; Service Principal auth is
   reserved for the `ci`, `accept`, and `prod` pipelines).
6. Run `dbt debug --profiles-dir .`.
7. Run `dbt deps`.
8. Run `dbt seed --profiles-dir .`.
9. Run `dbt build --profiles-dir .`.
10. Run `dbt docs generate --profiles-dir .`.

## Development conventions

- Keep top-level dbt folders standard: `models`, `macros`, `tests`, `seeds`, `analysis`.
- New source-aligned work starts in `models/bronze/staging/<source>/`.
- Cross-source integration belongs in `models/silver/ads/`.
- Reusable joins/business logic shared across `ads_*` models belong in
  `models/silver/intermediate/` (`int_<entity>`, typically `view`).
- Business-ready facts and dimensions belong in `models/gold/marts/`.
- Every model needs YAML documentation and tests for primary keys.
- Use `surrogate_key_bigint` for deterministic whole-number keys.
- Avoid `SELECT *` in production models.
- Add business owner metadata in YAML.

## Pull request checklist

- [ ] `dbt parse` passes.
- [ ] `dbt build --select <changed_model>+` passes locally or in CI.
- [ ] SQLFluff passes or exceptions are documented.
- [ ] Model and column descriptions are updated.
- [ ] Primary keys are tested for `unique` and `not_null`.
- [ ] Facts include relationship tests to dimensions.
- [ ] New master-data fields are documented in `docs/WORKBOOK_CONNECT.md`.

## Pre-commit hooks (not yet enabled)

SQLFluff is currently a manual step (run it yourself, or wait for CI) - there's
no `.pre-commit-config.yaml` in the repo yet. This is a reasonable thing to add
later; if/when it happens, keep it thin and limited to fast, local checks that
mirror what CI already gates, rather than duplicating everything CI does:

- `sqlfluff lint` (once a base `.sqlfluff` exists locally, not just `.sqlfluff-ci`)
  on staged `.sql` files only. Note that `.sqlfluff-ci` uses the dbt templater,
  so linting compiles the project and needs `dbt deps` plus the `ci` connection
  from your `.env` - slower than a pure-text hook.
- Basic file hygiene from the standard [`pre-commit/pre-commit-hooks`](https://github.com/pre-commit/pre-commit-hooks)
  repo: `check-yaml`, `end-of-file-fixer`, `trailing-whitespace`.

Deliberately **not** in pre-commit: `dbt parse`, `dbt-bouncer`, `dbt docs
generate`. All three need a resolved dbt project/manifest, which makes commits
slow and can fail for reasons unrelated to the change just made (e.g. a stale
`target/`) - those stay as CI-only gates (`ci.yml` / `cicd/azure-devops/ci.yml`).
