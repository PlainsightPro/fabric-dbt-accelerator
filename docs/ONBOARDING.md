# Onboarding guide

## Branch strategy

- Create your feature branch from `dev` and open your PR back into `dev`
  (slim CI builds your changes into an isolated `pr_<PR number>` schema on the
  Fabric CI warehouse, deferring unmodified refs to accept — see
  [`ci_architecture.md`](ci_architecture.md)).
- `accept` and `prod` receive code only through the weekly promotion PRs
  (`dev -> accept`, `accept -> prod`) — never push to them directly.

## Developer workflow

1. Clone the repository.
2. Create a Python virtual environment.
3. Install dependencies from `requirements/requirements_fabric.txt`.
4. Copy `profiles.yml.example` to `profiles.yml` and set `DBT_FABRIC_HOST` /
   `DBT_FABRIC_DATABASE` (or edit the dev defaults). Your schemas are automatically
   prefixed with `dev_<your username>_` — models and seeds alike — so you work in a
   fully isolated environment.
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
- Business-ready facts and dimensions belong in `models/gold/marts/`.
- Every model needs YAML documentation and tests for primary keys.
- Use `hash_bigint` for deterministic whole-number keys.
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
