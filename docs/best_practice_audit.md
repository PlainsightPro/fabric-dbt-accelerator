# Best-Practice Audit — fabric-dbt-accelerator vs. the dbt Vision Playbook

**Date:** 2026-07-15 · **Method:** read-only repository sweep, every claim cited to
a file (and line where useful). Baseline: the internal *dbt Best Practices —
Vision Playbook* (6 pillars). Excluded from the audit: `.venv/`, `dbt_packages/`,
`target/`, `.local/`, `backup/`.

Rating legend: ● implemented · ◐ partially / deviates · ○ missing.

## Scorecard

| # | Pillar                                | Rating | One-line verdict |
|---|---------------------------------------|:------:|------------------|
| 1 | Project structure / medallion         | ◐ | Clean bronze→silver→gold with per-source staging, but no landing/intermediate tiers, prefixed gold, no domain tags |
| 2 | SQL style & configuration             | ◐ | Strong CTE discipline and macros; `SELECT *` in silver finals and 11 redundant config blocks |
| 3 | Documentation                         | ◐ | 100 % model/source descriptions, grain + owner meta; no PII/SLA flags, sparse column docs, no CI docs gate |
| 4 | Operations, testing & orchestration   | ◐ | Selectors + slim CI exceed the playbook; no contracts, backfill, or exposure-driven runs; incremental models unguarded |
| 5 | Tooling                               | ◐ | SQLFluff pinned and in CI on both platforms; no extension recommendations, no evaluator/observability packages |
| 6 | Onboarding defaults                   | ○ | Workflow documented, but the entry point (`profiles.yml.example`) no longer exists — onboarding path is broken |

**Where we exceed the playbook:** the two-manifest slim CI
([`docs/ci_architecture.md`](ci_architecture.md)) — per-PR schema isolation,
defer-to-accept, fail-fast smoke test — goes beyond the playbook's plain
`state:modified+` requirement.

---

## Pillar 1 — Project structure / medallion layering

**Verdict:** the medallion core is implemented correctly; the optional tiers and
the naming/tagging refinements are not.

### Implemented
- Three-tier folder layout with layer tags and path-level materializations:
  [`dbt_project.yml:25-44`](../dbt_project.yml) (`bronze` views, `silver`/`ads`, `gold` tables).
- Staging organized **by source system**, one model per `source()`, source-scoped
  naming `stg_<system>__<entity>`:
  [`models/bronze/staging/`](../models/bronze/staging/) (`sales/`, `hr/`, `master_data/`).
- `stg_` / `ads_` prefixes used consistently across bronze and silver.
- YAML colocated per folder: `_sources.yml` next to each source's staging models,
  `_models.yml` per layer, [`models/gold/_exposures.yml`](../models/gold/_exposures.yml).
- Silver = integrated entities with survivorship/orphan handling:
  [`ads_sales_order.sql`](../models/silver/ads/ads_sales_order.sql) (COALESCE to
  unknown-member key 0), [`ads_product.sql`](../models/silver/ads/ads_product.sql)
  (`'Unmapped'` category default).
- Gold star schema with explicit unknown members:
  [`dim_customer.sql:19-32`](../models/gold/marts/dim_customer.sql), conformed
  [`dim_date.sql`](../models/gold/marts/dim_date.sql).
- Tags drive targeted runs via named selectors: [`selectors.yml`](../selectors.yml).

### Deviates
- **Gold models are prefixed** (`dim_customer`, `fact_sales`) — the playbook wants
  business-friendly, unprefixed names in Gold.
- **Gold materialized as `table`**, playbook default is `view`
  ([`dbt_project.yml:43`](../dbt_project.yml)). *Deliberate for Fabric* — see
  fairness notes below.
- **Silver path default is dead config:** `+materialized: view` at the path level,
  but every `ads_*` model overrides to `incremental` — the path default should be
  the real default.
- **Staging does more than atomic rename/cast:** surrogate-key hashing
  ([`stg_sales__customers.sql:21`](../models/bronze/staging/sales/stg_sales__customers.sql)),
  case normalization (`LOWER(email)`, `UPPER(country_code)`), audit columns.
  Defensible, but past the playbook's "atomic" bar.

### Missing
- No `landing/` tier (`lnd_` external tables / CDC).
- No `intermediate/` tier (`int_`, ephemeral) — business logic lives directly in
  `ads_*` models.
- No **domain tags** (`tag:finance` style) — only layer tags exist, so targeted
  runs work by layer, not by business domain.
- No snapshots (SCD limited to merge + `is_current` in
  [`ads_product.sql:53`](../models/silver/ads/ads_product.sql));
  [`snapshots/`](../snapshots/) holds only `.gitkeep`.
- No seeds — config commented out ([`dbt_project.yml:46-54`](../dbt_project.yml));
  demo data intentionally externalized (fairness notes).

## Pillar 2 — SQL style & configuration

**Verdict:** the style rules are largely lived, not just written down — the gaps
are consistency details and unused DRY infrastructure.

### Implemented
- Config block first, CTE runway (source CTEs → transforms → single `final`),
  one exit point — consistent across all 15 models (e.g.
  [`fact_sales.sql`](../models/gold/marts/fact_sales.sql),
  [`ads_sales_order.sql`](../models/silver/ads/ads_sales_order.sql)).
- Explicit column lists in bronze and gold finals; no `SELECT *` against sources.
- Uppercase keywords, explicit table aliasing, ≤ 120-char lines — enforced by
  [`.sqlfluff-ci`](../.sqlfluff-ci) (tsql dialect, dbt templater against the
  `ci` target).
- DRY macros: [`surrogate_key_bigint`](../macros/surrogate_key_bigint.sql)
  (BIGINT fold over `dbt_utils.generate_surrogate_key`),
  [`generate_schema_name`](../macros/generate_schema_name.sql) (per-target routing),
  [`limit_ci_rows`](../macros/limit_ci_rows.sql) (CI cost guard),
  [`assert_cross_db_access`](../macros/assert_cross_db_access.sql),
  [`drop_pr_schema`](../macros/drop_pr_schema.sql).
- [`packages.yml`](../packages.yml) constrains `dbt-labs/dbt_utils` to
  `>=1.1.0,<2.0.0`; `package-lock.yml` records the resolved version (1.4.1).

### Deviates
- **`SELECT * FROM final` in all four silver models**
  ([`ads_customer.sql:45`](../models/silver/ads/ads_customer.sql),
  [`ads_product.sql:60`](../models/silver/ads/ads_product.sql),
  [`ads_sales_order.sql:105`](../models/silver/ads/ads_sales_order.sql),
  [`ads_sales_rep.sql:36`](../models/silver/ads/ads_sales_rep.sql)) — bronze and
  gold spell out every column; silver should too.
- **11 of 15 models carry a `config()` block that only restates the project
  default** (6× bronze `materialized='view'`, 5× gold `materialized='table'`) —
  the playbook wants inheritance in `dbt_project.yml`, not scattered overrides.
  (The 4 silver `incremental` configs are legitimate overrides.)
- ~~Lint uses the **jinja templater with dbt builtins, not the dbt templater**~~ —
  resolved: `.sqlfluff-ci` now uses the dbt templater, so `ref`/`source` and
  package macros resolve for real. The `-- noqa: ST06` suppressions in
  [`ads_sales_order.sql:70`](../models/silver/ads/ads_sales_order.sql) and
  [`dim_date.sql:13`](../models/gold/marts/dim_date.sql) are left in place but no
  longer needed. Cost: linting now needs a warehouse connection, because
  `is_incremental()` in the silver models resolves `adapter.get_relation()`.
- ~~`hash_bigint` hand-rolls what `dbt_utils.generate_surrogate_key` provides~~ —
  resolved: replaced by [`surrogate_key_bigint`](../macros/surrogate_key_bigint.sql),
  which delegates key derivation to `dbt_utils` and only folds the result to the
  BIGINT that silver and gold require.

### Missing
- No base `.sqlfluff` for local development — only the CI config exists, so local
  linting requires knowing to pass `--config .sqlfluff-ci`.
- ~~**`dbt_utils` is declared but has zero usages** in `models/` or `tests/`.~~ —
  resolved: every bronze staging key now routes through
  `dbt_utils.generate_surrogate_key`.
- The repeated audit-column pattern (`source_system`, `dbt_loaded_at`, standard
  casts) is copy-pasted across staging models instead of centralized in a macro.

## Pillar 3 — Documentation

**Verdict:** breadth is excellent (every model, source, and exposure described,
with grain and owner metadata), but the playbook's governance layer — PII/SLA
flags, doc blocks, CI enforcement — is absent.

### Implemented
- **Model descriptions 16/16**, source descriptions 6/6 tables
  ([`models/bronze/staging/_models.yml`](../models/bronze/staging/_models.yml),
  [`models/silver/ads/_models.yml`](../models/silver/ads/_models.yml),
  [`models/gold/marts/_models.yml`](../models/gold/marts/_models.yml), the three
  `_sources.yml`).
- **Grain documented on every gold asset** via `meta.grain`
  ([`models/gold/marts/_models.yml`](../models/gold/marts/_models.yml), e.g.
  "one row per non-cancelled sales order line").
- `meta.owner` on all silver and gold models and all sources, plus
  `meta.medallion` / `meta.source_system` metadata.
- **Two well-formed exposures** with `type`, `maturity`, `url`, `owner`,
  `depends_on` ([`models/gold/_exposures.yml`](../models/gold/_exposures.yml)).
- Definition-of-Done PR checklist including documentation items
  ([`docs/ONBOARDING.md`](ONBOARDING.md), "Pull request checklist").

### Deviates
- **Column descriptions sparse:** roughly 20 of 70+ columns; bronze `_models.yml`
  has almost none (tests only). Measures and FKs (`net_sales_amount`,
  `category_code`, ...) are undocumented beyond their tests.
- Bronze **models** carry no `meta.owner` (ownership implied only via the
  source-level owner).
- Exposure URLs are placeholders (`https://app.powerbi.com/`).

### Missing
- **No PII/SPI flags and no refresh SLAs anywhere** — notable since
  [`ads_customer.sql`](../models/silver/ads/ads_customer.sql) materializes
  `email`, `full_name`, `city`.
- **No `{% docs %}` blocks** — all description text is inline; no reuse of
  business definitions.
- **CI never runs `dbt docs generate` and nothing fails on undocumented models**
  ([`ci.yml`](../.github/workflows/ci.yml) does parse + lint only); docs
  generation is a manual onboarding step.
- No `.github/PULL_REQUEST_TEMPLATE.md` — the DoD checklist is not surfaced at
  merge time.

## Pillar 4 — Operations, testing & orchestration

**Verdict:** selection/orchestration infrastructure is a strength (and slim CI
exceeds the playbook), but the run-type palette, contracts, and observability
are incomplete.

### Implemented
- [`selectors.yml`](../selectors.yml) as real orchestration infrastructure:
  `bronze`, `silver_and_upstream`, `gold_star_schema`, `ci_modified`
  (`state:modified+`), `full_build` (default).
- **Slim CI beyond playbook level:** two-manifest split (`--state` for selection,
  `--defer-state` → accept for resolution), per-PR schema isolation, cleanup
  workflow, colocation smoke test — [`docs/ci_architecture.md`](ci_architecture.md).
- **Source freshness with warn/error thresholds on all 6 source tables**, tiered
  by volatility (sales 7d/30d, hr 14d/60d, mdm 30d/90d), with `loaded_at_field`
  ([`models/bronze/staging/sales/_sources.yml`](../models/bronze/staging/sales/_sources.yml) etc.).
- **Testing ladder matches the playbook shape:** heavy `not_null`/`unique` on
  staging; lighter on silver; relationships concentrated at gold —
  `fact_sales` has 4 `relationships` tests to its dimensions
  ([`models/gold/marts/_models.yml`](../models/gold/marts/_models.yml)) — plus two
  singular business-rule tests in [`tests/`](../tests/).
- Silver uses incremental merge materializations for cost
  ([`ads_customer.sql:1-5`](../models/silver/ads/ads_customer.sql) and siblings);
  CI adds the [`limit_ci_rows`](../macros/limit_ci_rows.sql) row guard.

### Deviates
- **Only ~3 of the playbook's 5 run types** exist: local dev, slim CI, full build.
  Scheduled production runs execute **inside Fabric** by design (code ships to
  OneLake; see fairness notes) — so `tag:daily`-style schedules are out-of-repo
  and invisible here.
- **Incremental models lack `is_incremental()` guards** — every run merges the
  full source set; incremental in name, not in load profile.
- Freshness thresholds are defined but **never invoked** — no
  `dbt source freshness` step in any pipeline.

### Missing
- No backfill/replay flow or selector (no full-refresh path, no dated backfill).
- No **exposure-driven refresh** (`--select +exposure:<name>` unused) — exposures
  are documentation-only.
- No **model contracts or constraints** (`contract: enforced` nowhere), notable at
  the gold BI boundary.
- No consumer of `run_results.json` / observability package (no elementary, no
  external catalog integration).

## Pillar 5 — Tooling

**Verdict:** the linting/pinning basics are solid; the developer-experience and
package layers the playbook prescribes are missing.

### Implemented
- SQLFluff pinned (`sqlfluff==4.2.2`, `sqlfluff-templater-dbt==4.2.2`) alongside
  exact dbt pins in
  [`requirements/requirements.txt`](../requirements/requirements.txt);
  `require-dbt-version` guard in [`dbt_project.yml`](../dbt_project.yml).
- Lint runs in CI on **both** platforms
  ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml),
  [`cicd/azure-devops/ci.yml`](../cicd/azure-devops/ci.yml)).
- `dbt_utils` exactly pinned in [`packages.yml`](../packages.yml).

### Deviates
- Lint output is plain text — no `--format github-annotation` / ADO equivalent,
  so failures don't surface as inline PR annotations.
- The "small pinned set of community packages" is a set of one (and unused, see
  Pillar 2).

### Missing
- **`.vscode/extensions.json` does not exist although `README.md` references it**
  (dangling pointer) — no dbt Power User or SQLFluff extension recommendations;
  `.vscode/` holds only a `settings.json` unrelated to dbt.
- No `dbt_project_evaluator`, `dbt_expectations`, or `elementary`.

## Pillar 6 — Onboarding defaults

**Verdict:** the documented flow is right, but its entry point is broken —
a new developer cannot complete step 4.

### Implemented
- Ordered onboarding workflow — venv → requirements → profile → `az login` →
  `dbt debug` → `dbt deps` → build → docs
  ([`docs/ONBOARDING.md`](ONBOARDING.md)); README quick start mirrors it.
- `DBT_PROFILES_DIR` set in every CI/CD workflow; local docs consistently use
  `--profiles-dir .`.
- SQLFluff installed via requirements and required by the PR checklist.

### Deviates
- `DBT_PROFILES_DIR` as an env var is CI-only guidance; the local flow relies on
  remembering the `--profiles-dir .` flag.
- SQLFluff-before-PR is a manual checklist item — nothing runs it automatically.

### Missing
- **`profiles.yml.example` was deleted from the repo but is still onboarding
  step 4 and README quick-start step 3** — following the docs fails at
  `cp profiles.yml.example profiles.yml`. (A committed
  [`profiles.yml`](../profiles.yml) exists instead; docs must be re-pointed or
  the example restored.)
- No `.vscode/extensions.json` (see Pillar 5).
- No pre-commit hooks (`.pre-commit-config.yaml` absent).

---

## Fairness notes — where deviating is (probably) right

Not every gap is a defect; three deviations are deliberate for this stack:

1. **Gold as `table`, not `view`.** On a Fabric Warehouse serving BI directly,
   materialized gold tables are a defensible performance/cost choice; the
   playbook's view-default assumes a cheaper compute-on-read engine.
2. **No in-repo production schedule.** The deployment contract ships *code* to
   OneLake and lets the Fabric runtime execute dbt on its own schedule
   ([`cicd/README.md`](../cicd/README.md)). `tag:daily`-style selectors would
   belong to that runtime's configuration, not this repo.
3. **No seeds.** Demo CSVs were intentionally externalized to the `LH_source`
   lakehouse and read via `source()` — closer to production reality than
   seed-loading reference data through dbt.

## Remediation backlog (prioritized, not yet implemented)

### P1 — broken or nearly free
| Item | Pillar | Notes |
|------|--------|-------|
| Restore `profiles.yml.example` or re-point ONBOARDING/README to the committed `profiles.yml` | 6 | Unbreaks onboarding step 4 |
| Create `.vscode/extensions.json` (dbt Power User, SQLFluff) | 5/6 | Also fixes the dangling README reference |
| Add `is_incremental()` delta predicates to the 4 `ads_*` models | 4 | Turns nominal incrementals into real ones |
| Delete the 11 redundant per-model `config()` blocks | 2 | Pure cleanup; inheritance already in `dbt_project.yml` |

### P2 — quality gates
| Item | Pillar | Notes |
|------|--------|-------|
| Column descriptions + `meta.pii` / `meta.sla`, starting with `ads_customer` and gold | 3 | PII flags first — customer attributes are live |
| `dbt docs generate` + docs-coverage gate in CI (e.g. `dbt_project_evaluator`) | 3/5 | Makes the DoD checklist enforceable. Note: `dbt_project_evaluator` 1.3.2 crashes `dbt parse` on fabric-type targets (unguarded `graph` access in its fabric branch) — needs a workaround (e.g. run on DuckDB or vendor a patched copy) |
| `.github/PULL_REQUEST_TEMPLATE.md` from the ONBOARDING checklist | 3 | Surfaces DoD at merge time |
| SQLFluff `--format github-annotation` (+ ADO equivalent); base `.sqlfluff` for local use | 5/2 | Inline PR feedback; no `-ci` flag knowledge needed |
| `dbt source freshness` step in CI or a scheduled pipeline | 4 | Thresholds exist, run them |

### P3 — architecture evolution
| Item | Pillar | Notes |
|------|--------|-------|
| Gold contracts (`contract: enforced`) + constraints | 4 | Protects the BI boundary |
| Domain tags + exposure-driven selectors (`+exposure:<name>`) | 1/4 | Unlocks report-scoped refresh |
| `intermediate/` tier when `ads_*` logic grows | 1 | Not urgent at current model count |
| Adopt `dbt_utils` where it replaces custom logic — or drop the dependency | 2 | Declared-but-unused today |
| Pre-commit config (sqlfluff, dbt parse) | 6 | Automates the manual checklist |
| Observability (elementary / artifact consumer) | 4/5 | run_results.json currently unused |
