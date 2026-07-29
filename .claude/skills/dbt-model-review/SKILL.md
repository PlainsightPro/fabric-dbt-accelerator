---
name: dbt-model-review
description: >
  Use when reviewing a dbt pull request or auditing existing dbt models against
  Plainsight standards — runs a single pass over structure, SQL style, testing,
  documentation, and orchestration impact, and reports findings by severity.
  Invoke with /dbt-model-review. Use this for reviewing; use the individual
  dbt-* skills when authoring.
---

# dbt Model Review

Review the changed dbt files against Plainsight's standards. Load the detailed rules from
the sibling skills as needed: `dbt-project-structure`, `dbt-sql-style`, `dbt-testing`,
`dbt-documentation`, `dbt-run-and-selectors`.

## Scope the review

```sh
git diff --name-only origin/main...HEAD -- '*.sql' '*.yml'
```

Review only the changed files plus anything the change breaks (renamed models, changed
grain, altered tags). If the diff renames or removes a model, check inbound `ref()` calls,
exposure `depends_on`, and `selectors.yml` before anything else.

## Review passes

**1. Placement & naming**
- Is the model in the layer its content justifies? Staging that joins, or Gold that
  re-derives ADS logic, is misplaced.
- Does the filename match the layer pattern (`stg_`, `int_`, `ads_`, `lnd_`, or a bare
  business name in Gold)?
- Is materialization inherited from `dbt_project.yml` rather than an inline override?

**2. SQL body**
- Config block first, blank line, then CTEs in dependency order with block comments.
- One `final` CTE, one closing select. No `select *` elsewhere.
- Explicit column lists, `snake_case` aliases, each `ref()`/`source()` aliased once.
- Repeated expressions extracted into a macro or replaced with `dbt_utils`.
- No hardcoded dates/environments — `var()` / `env_var()`.
- Incremental models have a working `is_incremental()` filter.

**3. Tests**
- Staging: key `not_null` + `unique`, `accepted_values` on enums, source `freshness`.
- ADS/Gold: key uniqueness, `relationships` between facts and dimensions, contracts.
- No new tests piled onto ephemeral intermediate models.
- Watch for tests that were **weakened or deleted** to make CI pass — that's a finding, not a fix.

**4. Documentation**
- Description covers purpose, grain, and refresh expectation.
- Every new column has a business-meaning description; PII/SPI flagged.
- Owner/team set. Repeated business terms use `doc()` rather than copy-paste.
- New downstream consumers have an exposure with `url`, `owner`, `maturity`, `depends_on`.

**5. Orchestration impact**
- Did a tag, exposure name, or selector name change? Those are contracts referenced by
  scheduled jobs — flag any rename.
- Does a new model need to join an existing cadence tag, or will it silently never run?
- Could this change blow up cost — a new full-refresh table where incremental was intended,
  or a heavy `COUNT DISTINCT` in a frequently-built model?

## Reporting

Report findings ranked most severe first, each with file, line, and the concrete failure:

| Severity | Meaning |
|---|---|
| **Critical** | Will produce wrong data, break a scheduled job, or expose PII |
| **Warning** | Silent quality or cost degradation — missing tests, weakened assertions, undocumented columns |
| **Info** | Style and consistency — naming, CTE structure, DRY opportunities |

State what's wrong and what the fix is. Don't restate rules the code already follows, and
don't pad the list — a clean model should get a short report saying so.

## Final gate

- [ ] `dbt build --select state:modified+` is green.
- [ ] `sqlfluff lint` on the changed models passes.
- [ ] `dbt docs generate` introduces no undocumented items.
