## Summary



## Pull request checklist

Kept in sync with [`docs/ONBOARDING.md`](../docs/ONBOARDING.md) - update both if this changes.

- [ ] `dbt parse` passes.
- [ ] `dbt build --select <changed_model>+` passes locally or in CI.
- [ ] SQLFluff passes or exceptions are documented.
- [ ] Model and column descriptions are updated.
- [ ] Primary keys are tested for `unique` and `not_null`.
- [ ] Facts include relationship tests to dimensions.
- [ ] New master-data fields are documented in `docs/WORKBOOK_CONNECT.md`.
