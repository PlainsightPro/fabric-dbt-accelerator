---
name: dbt-project-structure
description: >
  Use when adding, moving, renaming, or reviewing the placement of models in a
  dbt project — deciding which layer a model belongs to (landing, staging,
  intermediate, ADS, gold), naming it, choosing its materialization, or setting
  path-level defaults in dbt_project.yml. Applies Plainsight's Bronze/Silver/Gold
  layering conventions. Not for writing the SQL body itself (see dbt-sql-style).
---

# dbt Project Structure

Source of truth: [`docs/technical-guidelines/dbt/project-structure.md`](../../../docs/technical-guidelines/dbt/project-structure.md)

## Golden rule

Folders describe **what problem the models solve**, not who wrote them. Keep dbt's
default top-level skeleton (`models/`, `snapshots/`, `tests/`, `macros/`,
`analyses/`, …) — organize *within* those directories, never rename or reshuffle them.

## Where does this model go?

Ask in order. Stop at the first "yes".

| Question | Layer | Folder | Name | Materialization | Medallion |
|---|---|---|---|---|---|
| Does raw data need preprocessing before it's queryable (external tables, CDC, JSON/Parquet parsing, incremental-only ingestion)? | Landing *(optional)* | `models/bronze/landing/<source>/` | `lnd_<source>_<entity>` | `external` or `view` | Bronze |
| Is this a 1:1 rename/cast/normalize of a single `source()` table? | Staging | `models/bronze/staging/<source>/` | `stg_<source>_<entity>` | `view` | Bronze |
| Is this reusable business logic shaping inputs for ADS (joins, filters, flattening)? | Intermediate | `models/silver/intermediate/<domain>/` | `int_<domain>_<action>` | `ephemeral` (or `view` if reused broadly) | Silver |
| Is this a harmonized cross-source entity other teams should build on (SCD, survivorship, enrichment)? | ADS | `models/silver/ads/` | `ads_<entity>` | `table` / `incremental` | Silver |
| Is this consumed directly by BI or ML? | Gold | `models/gold/<consumption_pattern>/` | business name, no prefix | `view` by default | Gold |

**Skip landing entirely** when staging can reference `source()` directly. Don't create
the folder "just in case".

## Hard rules per layer

- **Staging**: exactly one model per `source()` table. Rename, cast, normalize — **never
  join or aggregate**. Group folders by source system so `dbt build --select staging.sap+`
  works intuitively.
- **Intermediate**: group by business domain (`finance`, `marketing`, `platform`), not by
  author or ticket. Verbs carry intent: `int_finance_orders_enriched`. Don't duplicate
  staging logic or pre-compute presentation metrics here.
- **ADS**: this is the reusable interface Gold consumes. `dbt snapshot` models live here.
  Contracts, tests, and ownership go in `_models.yml` beside the models.
- **Gold**: keep transformations light — expose curated tables, don't re-implement ADS
  logic. Organize by consumption pattern (`gold/star_dim_fact/`, `gold/feature_store/`).
  Promote from `view` to `table`/`incremental` only when SLA or cost demands it.

## Reference tree

```
models/
├─ bronze/
│  ├─ landing/                  # optional
│  │  └─ sap/
│  │     ├─ _sources.yml
│  │     └─ lnd_sap_charges.sql
│  └─ staging/
│     └─ sap/
│        ├─ _sources.yml        # definitions, freshness, owner metadata
│        ├─ stg_sap_charges.sql
│        └─ stg_sap_customers.sql
├─ silver/
│  ├─ intermediate/
│  │  └─ int_orders_enriched.sql
│  └─ ads/
│     ├─ ads_customer.sql
│     └─ _models.yml            # contracts, ownership, tests
└─ gold/
   ├─ star_dim_fact/
   │  ├─ d_customer.sql
   │  └─ f_orders.sql
   └─ feature_store/
```

## YAML placement

- `_sources.yml` sits **beside the staging models it describes** — with freshness,
  descriptions, and source-level tests.
- `_models.yml` sits **per folder**, so business context and ownership stay synchronized
  with the transformations.
- Never centralize YAML into one top-level file. Colocation is the convention.

## Tags

Apply tags for lineage groups and cadence (`["stripe"]`, `["incremental"]`, `["daily"]`)
so targeted runs like `dbt run --select tag:finance` work. Tag names become orchestrator
contracts — see the `dbt-run-and-selectors` skill before renaming one.

## Checklist before you finish

- [ ] Model is in the layer folder its *content* justifies, not the one that was convenient.
- [ ] Filename matches the layer's naming pattern (kebab is for docs; models are snake_case).
- [ ] Materialization comes from a `dbt_project.yml` path default where possible, not an
      inline `{{ config() }}` override.
- [ ] A `_models.yml` entry exists in the same folder with description, owner, and tests.
- [ ] Staging models don't join. Gold models don't re-derive ADS logic.
- [ ] Any tag you introduced is one an orchestrator or selector can rely on.
