# Onboarding guide

## Developer workflow

1. Clone the repository.
2. Create a Python virtual environment.
3. Install dependencies from `requirements.txt`.
4. Copy `profiles.yml.example` to `profiles.yml` and fill in Fabric details.
5. Run `az login`.
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
