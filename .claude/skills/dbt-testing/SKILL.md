---
name: dbt-testing
description: >
  Use when adding, reviewing, or debugging tests in a dbt project — generic tests
  (not_null, unique, accepted_values, relationships), singular tests, custom
  generic tests in tests/generic/, source freshness thresholds, contracts, and
  deciding how much coverage each layer needs. Applies Plainsight's testing
  ladder and per-layer coverage matrix.
---

# dbt Testing

Source of truth: [`docs/technical-guidelines/dbt/operations-and-testing.md`](../../../docs/technical-guidelines/dbt/operations-and-testing.md)

## Non-negotiable

**Ship nothing with failing tests.** CI pipelines and scheduled jobs must fail fast on any
broken test. A production deployment without a green `dbt test` (or `dbt build`) is not allowed.

## Where to spend test budget

Coverage is not uniform. Two tactics drive everything:

- **Hit sources hard** — saturate staging/source models with `not_null`, `unique`,
  freshness, and schema-conformance tests so bad data is blocked *before* it propagates.
- **Guard dimensions & facts** — in ADS/Gold, prioritize relationship tests, contracts,
  and business constraints so metrics stay trustworthy.

| Layer | Core tests |
|---|---|
| Staging | `not_null`, `unique`, `accepted_values`, source `freshness` |
| Intermediate | **Minimize.** Only high-risk models, and mostly during development |
| ADS | Key uniqueness, relationship depth |
| Gold (dims/facts) | Contracts, metric-specific assertions, dimensional constraints (e.g. Type 2 checks) |

Ephemeral intermediate models should **not** accumulate dedicated test suites — lean on
staging coverage upstream and ADS/Gold constraints downstream.

## The testing ladder

**1. Built-in data quality**

- `not_null` + `unique` on natural or surrogate keys in staging and ADS/Gold. Add them to
  intermediate models only when the model is genuinely high-risk.
- `relationships` to enforce referential integrity between Gold dimension and fact models.
- `accepted_values` on every enum and status field — this is what catches silent drift.

**2. Business logic, anomaly tests & freshness**

- Reusable custom generic tests go in `tests/generic/` (e.g. `test_positive_amounts.sql`).
- Scenario-specific checks go in singular tests — a SQL query that returns zero rows when
  healthy.
- Parameterize tests via macros so new models inherit the logic automatically rather than
  copying assertions.
- Configure `freshness` per critical source with both thresholds, e.g. warn after 18h,
  error after 26h.

```yaml
sources:
  - name: commerce
    freshness:
      warn_after: {count: 18, period: hour}
      error_after: {count: 26, period: hour}
    loaded_at_field: updated_at
    tables:
      - name: orders
        columns:
          - name: order_id
            tests: [not_null, unique]
          - name: order_status
            tests:
              - accepted_values:
                  values: ['pending', 'shipped', 'cancelled']
```

## Running tests

| Goal | Command |
|---|---|
| Test a model and everything downstream | `dbt build --select my_model+` |
| Test only what changed (Slim CI) | `dbt build --select state:modified+` |
| Check source freshness | `dbt source freshness` |
| Rerun only failures | `dbt build --select result:fail+ --state <path>` |

`dbt build` interleaves runs and tests in DAG order, so a failing test stops bad data from
reaching children. Prefer it over separate `dbt run` + `dbt test`.

## Debugging a failing test

1. `dbt test --select <test_name> --store-failures` — materialize failing rows to inspect.
2. Check whether the failure is a **data** problem (upstream regression → fix the source or
   add a staging filter) or a **contract** problem (the test encodes an assumption that's no
   longer true → change the test *and* the model description together).
3. Never widen or delete a test to make CI green. If a model is legitimately broken and
   blocking the pipeline, tag it `quarantined` and exclude it via a selector rather than
   weakening the assertion.

## Checklist

- [ ] Every staging model has key `not_null` + `unique`, and `accepted_values` on enums.
- [ ] Every critical source has `freshness` with both warn and error thresholds.
- [ ] Gold facts have `relationships` tests against their dimensions.
- [ ] Repeated assertions were extracted into `tests/generic/` or a macro.
- [ ] No new tests were added to ephemeral intermediate models.
- [ ] Descriptions in `_models.yml` agree with what the tests enforce.
- [ ] `dbt build` is green locally before opening the PR.
