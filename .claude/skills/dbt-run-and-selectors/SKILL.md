---
name: dbt-run-and-selectors
description: >
  Use when choosing or writing dbt run commands, node selection syntax, or
  orchestration config — Slim CI with state:modified, exposure: selectors,
  reusable named selectors in selectors.yml, tag-based cadence separation,
  backfills, and performance/cost tuning of materializations. Applies
  Plainsight's run vocabulary and orchestration conventions.
---

# dbt Runs, Selectors & Orchestration

Source of truth: [`docs/technical-guidelines/dbt/operations-and-testing.md`](../../../docs/technical-guidelines/dbt/operations-and-testing.md)

Keep dbt operations boring. Treat runs as production software pipelines — even when
analysts write the SQL.

## Run vocabulary

- **Development** — local, iterative, fast feedback.
- **Pre-Prod** — automated validation on feature branches or staging datasets.
- **Production** — scheduled jobs that own SLAs and downstream contracts.

## Run types

| Scenario | Trigger | Command | Scope / notes |
|---|---|---|---|
| Local development | Developer CLI / IDE | `dbt build --select my_model+` | Fast feedback on a model plus its dependencies |
| Pull request (Slim CI) | CI runner | `dbt build --select state:modified+` | Touch only changed models + children; upload artifacts for review |
| Scheduled production | Orchestrator | `dbt build --select tag:daily` or `dbt build` | Full slices aligned to SLAs; rely on stored state for performance |
| Backfill / replay | Manual CLI / job | `dbt run --select fact_orders --vars '{start_date: "..."}'` | Recompute historical windows or recover from upstream issues |
| Exposure-driven refresh | Downstream refresh dependency | `dbt build --select +exposure:sales_exec_dashboard` | Rebuild only what a report depends on, ahead of its own refresh |

Document selectors, targets, threads, and variables for each scenario so operators rerun
them consistently. Prefer `dbt build` over separate `run` + `test` — it interleaves tests in
DAG order so failures stop bad data reaching children.

## Exposures as selectors

Exposures aren't just documentation. The `exposure:` selector method lets an orchestrator
target exactly the models a downstream consumer needs, instead of a full run or a best-guess tag.

```sh
# rebuild everything upstream of one exposure before its scheduled refresh
dbt build --select +exposure:sales_exec_dashboard

# dry-run the scope for impact analysis before changing a shared model
dbt list --select +exposure:sales_exec_dashboard
```

## Reusable named selectors

Define selection criteria **once** in `selectors.yml` and reference them by name, so
scheduled jobs and CI stay consistent instead of hardcoding long `--select` strings across
environments.

A single exposure can be fed by models on different refresh cadences, and a single tag
(e.g. `daily`) can span unrelated exposures. **Intersect `exposure:` with `tag:`** to run
"only the daily-cadence models feeding this dashboard" separately from its weekly slice —
instead of over- or under-building.

`exclude` carves models back out — e.g. skip anything tagged `quarantined` (known-broken or
under repair) so one bad model doesn't block the whole daily build.

```yaml
selectors:
  - name: sales_dashboard_daily
    description: "Daily-cadence models feeding the sales exec dashboard"
    definition:
      method: intersection
      value:
        - method: exposure
          value: sales_exec_dashboard
          parents: true
        - method: tag
          value: daily
      exclude:
        - method: tag
          value: quarantined

  - name: sales_dashboard_weekly
    description: "Weekly-cadence models feeding the sales exec dashboard"
    definition:
      method: intersection
      value:
        - method: exposure
          value: sales_exec_dashboard
          parents: true
        - method: tag
          value: weekly
```

Two orchestrator jobs then call `dbt build --selector sales_dashboard_daily` and
`dbt build --selector sales_dashboard_weekly` — cadence and downstream ownership stay
consistent, without one job over-building or the other missing dependencies.

!!! warning "Names are contracts"
    Once orchestrator or CI configs reference an exposure name or selector name, **keep it
    stable**. Renaming one silently breaks a scheduled job.

## Lineage & metadata visibility

- Publish `dbt docs generate` artifacts on every production deployment so the DAG, schema
  catalog, and test results stay current.
- Feed `manifest.json` and `run_results.json` into the data catalog or lineage tooling so
  business users can trace dependencies without reading SQL.

## Performance & cost

- Prefer incremental models for large tables; verify `is_incremental()` filters actually
  limit processing to new partitions.
- Profile slow queries against the warehouse query plan and refactor heavy constructs
  (e.g. `COUNT DISTINCT`) into pre-aggregations.
- Revisit materializations periodically — ephemeral chains are great for small datasets, but
  promoting a high-cost intermediate to a table can cut both runtime and spend.

## Checklist

- [ ] The command matches the scenario in the run-types table — no ad-hoc full `dbt build` in CI.
- [ ] Repeated `--select` strings were promoted into a named selector in `selectors.yml`.
- [ ] Scheduled jobs reference selector names, not inline selection syntax.
- [ ] Exposure and selector names referenced by orchestrators were not renamed.
- [ ] Backfills pass their window via `--vars`, not by editing the model.
- [ ] Incremental models were checked for a working `is_incremental()` filter.
