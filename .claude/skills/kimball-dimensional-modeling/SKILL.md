---
name: kimball-dimensional-modeling
description: >
  Use when designing, creating, or reviewing Gold star-schema models in a dbt
  project — fct_ and dim_ models, declaring grain, choosing a fact table type
  (transaction, periodic snapshot, accumulating snapshot), surrogate/natural/
  unknown-member keys, conformed and role-playing dimensions, SCD types,
  degenerate and junk dimensions, bridge tables, and the date dimension.
  Applies Kimball's dimensional modeling techniques on top of Plainsight's
  Bronze/Silver/Gold layering. Not for deciding which layer a model belongs to
  (see dbt-project-structure).
---

# Kimball Dimensional Modeling

Adapted from [`appspace/kwwhat`](https://github.com/appspace/kwwhat/tree/main/.claude/skills/kimball-dimensional-modeling)
(MIT) and the Kimball Group's dimensional modeling techniques, rewritten for this project's
conventions. Per-model review list: [references/checklist.md](references/checklist.md).

## Where this sits

The star schema is the **Gold** layer (`models/gold/marts/`). Kimball modeling decides the
*shape* of Gold; `dbt-project-structure` decides the layering around it:

- Business logic, survivorship, and SCD history live in **Silver ADS**. Gold dims and facts
  are a thin projection of ADS — rename `_pk` → `_key`, add the unknown member, select the
  consumer-facing columns. Never re-derive ADS logic in Gold.
- Surrogate keys are built **once**, in staging/ADS, with `surrogate_key_bigint` (BIGINT,
  deterministic). Don't use `dbt_utils.generate_surrogate_key` — see the macro header for why.

## Decision flow

```
Model requested
  1. Identify the business process (orders, shipments, payments…) — one fact per process
  2. Declare the grain — if you can't, STOP and ask
  3. Identify the dimensions that are true at that grain
  4. Identify the facts (measures) that are true at that grain
  5. Check for an existing conformed dim before creating one
  6. Run references/checklist.md — block on any blocking item
```

This is Kimball's four-step design process (steps 1–4). Do them in order: dimensions and
measures that aren't true at the declared grain cause fan-out.

## Step 1–2 — Business process and grain

Write the grain down before any SQL, in `meta.grain` in `_models.yml`:

> "One row represents one **[event/entity]** per **[time/context]**."

Prefer the **atomic** grain (the lowest level the source captures). It can always be rolled
up; an aggregated grain can't be drilled into. Never infer grain from column names alone.

## Fact table types

| Type | One row per | Measures | Example |
|---|---|---|---|
| Transaction | event at a point in time | additive | `fct_sales` — one row per order line |
| Periodic snapshot | entity per regular period | often semi-additive (balances, stock) | daily inventory per product per warehouse |
| Accumulating snapshot | process instance, updated as milestones occur | durations/lags between milestones; several date keys | order → shipped → delivered |
| Factless | event or coverage with no measure | `count(*)` only | student attendance, promotion coverage |

Pick one type per fact. Mixing grains (e.g. header and line amounts) in one fact is a blocking issue —
allocate header measures down to line, or build a separate header-grain fact.

## Keys

| Layer | Primary key | Foreign keys | Natural key |
|---|---|---|---|
| Silver ADS | `<entity>_pk` | `<entity>_pk`, `coalesce(..., 0)` for misses | source name, e.g. `customer_id` |
| Gold dim | `<entity>_key` (BIGINT) | — | kept as-is, `'UNKNOWN'` for the unknown member |
| Gold fact | `<process>_fact_key` or the grain key | `<entity>_key` → dims only | degenerate dims only (see below) |

- **Unknown member**: every dim carries a key-`0` row built in an `unknown_member` CTE and
  `union all`-ed with the known members (see `dim_customer.sql`). Fact FKs that miss resolve to
  `0` in ADS, so facts never carry null FKs and inner joins never drop rows.
- Facts join to dims on surrogate keys **only**, never natural keys.
- Every dim PK and the fact grain key get `not_null` + `unique`; every fact FK gets a
  `relationships` test to its dim.
- Date dims are the exception to hashed keys: use a smart `int` key `yyyymmdd`
  (`cast(convert(char(8), d, 112) as int)`), so facts can derive it without a lookup.

## Measures

- Default to **additive** (sums across every dimension). Store the additive components, not
  the ratio: `net_sales_amount` and `quantity`, not `avg_unit_price`.
- **Semi-additive** (balances, stock levels — not summable over time) and **non-additive**
  (ratios, percentages) must say so in the column description.
- A measure in a `dim_` model is a blocking issue. Descriptive text in a `fct_` model belongs
  in a dim (or is a degenerate dim).

## Dimension techniques

| Technique | Use when | Rule |
|---|---|---|
| **Conformed dim** | Same entity used by several facts | One `dim_<entity>` shared by all facts. Search before creating: `find dbt/models/gold -name "dim_*.sql"`. A second dim for the same entity at the same grain is blocking. |
| **Role-playing dim** | One dim referenced twice by a fact (order date, ship date) | One physical dim; distinct FK names (`order_date_key`, `ship_date_key`). Expose roles as views or semantic-model relationships, not copied tables. |
| **Degenerate dim** | Transaction identifier with no attributes (order number) | Keep it on the fact (`order_number`); document it. No dim table. |
| **Junk dim** | Several low-cardinality flags/codes cluttering the fact | Combine into one `dim_<process>_profile` with one row per observed combination. |
| **Outrigger / snowflake** | Hierarchy inside a dim (product → category) | Flatten it into the dim (`dim_product` carries category columns). Snowflaking is the exception, not the default. |
| **Bridge table** | Many-to-many (account ↔ customers, multi-valued diagnoses) | `bridge_<a>_<b>` with a weighting factor if measures must allocate. Document the double-counting risk. |
| **Date dim** | Every fact with a date | Conformed `dim_date` spanning the full needed range, with an unknown/`19000101` row. Don't derive it only from dates seen in one fact — dates with no sales vanish. |

## Slowly changing dimensions

Declare the SCD type in the model description for any dim whose attributes can change:

| Type | Behaviour | Implementation here |
|---|---|---|
| 0 | Never changes (original value) | Plain column |
| 1 | Overwrite, no history | ADS `incremental` with `unique_key` — the default |
| 2 | New row per change | `dbt snapshot` in Silver ADS; Gold dim exposes `valid_from`, `valid_to`, `is_current`; the PK becomes the version key, natural key + `valid_from` unique |
| 6 / hybrid | Type 2 rows plus Type 1 "current" columns | Document per column which type applies |

With SCD 2, facts must join to the version valid at the event date — resolve the version key
in ADS, not in BI. A mutable attribute with no declared type is a blocking issue.

## Red flags — STOP

- SQL written before the grain is declared
- Measures in a dim, or descriptive attributes in a fact
- A fact FK pointing at a natural key, or a null FK (should be `0`)
- Mixed grains in one fact, or a join that fans out the declared grain
- A new dim duplicating an existing conformed dim
- A dim without an unknown member, or without `not_null` + `unique` on its key
- A mutable attribute with no declared SCD type
- Gold re-implementing logic that belongs in ADS

## Rationalizations to resist

| You're thinking… | Reality |
|---|---|
| "The grain is obvious from the name" | Write it in `meta.grain`. Reviewers and future sessions need it. |
| "I'll add the SCD type later" | If it can change, history is being lost from today. Declare it now. |
| "Natural keys are fine for this join" | They break on source-system changes and re-keying. Join on `_key`. |
| "I'll aggregate in the fact to save rows" | You lose drill-down forever. Keep the atomic grain; aggregate in a separate model if needed. |
| "Just one ratio column in the fact" | Store numerator and denominator; ratios don't sum. |
