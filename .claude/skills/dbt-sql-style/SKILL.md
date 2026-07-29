---
name: dbt-sql-style
description: >
  Use when writing or editing the SQL body of a dbt model, a macro, or a Jinja
  expression — CTE structure, config block placement, aliasing, explicit column
  lists, DRY extraction into macros or dbt_utils, and dbt_project.yml config
  inheritance. Applies Plainsight's dbt SQL style guide. Not for deciding which
  folder a model belongs in (see dbt-project-structure).
---

# dbt SQL Style & Configuration

Source of truth: [`docs/technical-guidelines/dbt/sql-style-and-configuration.md`](../../../docs/technical-guidelines/dbt/sql-style-and-configuration.md)

## Model file skeleton

Every model follows this shape:

```sql
{{ config(
    materialized = 'incremental',
    unique_key = 'order_id',
    on_schema_change = 'append_new_columns'
) }}

with
-- Pull only the columns we need from the source system
source_orders as (
    select
        order_id,
        customer_id,
        order_total_cents,
        updated_at
    from {{ source('commerce', 'orders') }}
    {% if is_incremental() %}
        where updated_at >= (select coalesce(max(updated_at), '1900-01-01') from {{ this }})
    {% endif %}
),

-- Apply business-friendly renames and units
staged_orders as (
    select
        order_id,
        customer_id,
        {{ cents_to_dollars('order_total_cents') }} as order_total_usd,
        updated_at
    from source_orders
),

-- Final CTE prepares the output rows
final as (
    select
        order_id,
        customer_id,
        order_total_usd,
        updated_at,
        current_timestamp as loaded_at
    from staged_orders
)

select * from final
```

## Rules

| Rule | Do | Don't |
|---|---|---|
| **Config first** | Open with `{{ config(...) }}` (or a short comment), then a blank line before the first CTE | Bury config mid-file or scatter it |
| **CTE runway** | Order CTEs sources ➜ transformations ➜ final projection; short comment above each major block | Nest subqueries |
| **One exit point** | End with a single `final` CTE, then `select * from final` | Multiple trailing selects or a bare final query |
| **Explicit columns** | List every column | `select *` (except the closing `select * from final`) |
| **Aliases** | lowercase `snake_case`, meaningful, alias each `ref()`/`source()` exactly once | single-letter aliases like `a`, `b`, `t1` |
| **Keywords** | UPPERCASE SQL keywords | mixed case |
| **Joins** | Each join on its own line, indented under the `from` | joins trailing on the same line |
| **Line length** | ≤ 120 characters, for Git-friendly diffs | long one-liners |
| **Constants** | Read runtime toggles from `var()` / `env_var()` | hardcode dates, environments, thresholds |

## DRY — before writing a transformation

Ask, in order:

1. Have I seen this pattern before in this project? → extract a macro.
2. Can a vetted `dbt_utils` macro do it? → use it instead of writing your own.
3. Should this be a `ref()`'d model rather than repeated logic? → build it once in ADS.
4. Will other models need this logic? → macro or model, not copy-paste.

```sql
-- macros/cents_to_dollars.sql
{% macro cents_to_dollars(column_name) %}
    {{ column_name }} / 100.0
{% endmacro %}
```

```sql
-- vetted community macros beat hand-rolled ones
select
    {{ dbt_utils.generate_surrogate_key(['customer_id', 'order_date']) }} as order_key,
    {{ dbt_utils.safe_divide('revenue', 'order_count') }} as avg_order_value
from orders
```

Don't reinvent the wheel — dbt Labs vets a set of open-source packages. Pin every version
in `packages.yml`.

Background: [DRY — Don't Repeat Yourself](../../../docs/technical-guidelines/architectural-principles/dry-dont-repeat-yourself.md).

## Configuration inheritance

Set defaults **high** in `dbt_project.yml` and override only when genuinely necessary:

```yaml
models:
  my_project:
    ads:
      +materialized: table
      +on_schema_change: append_new_columns
    gold/logistics:
      +incremental_strategy: merge
      +unique_key: order_id
```

Prefer path-level settings so a reviewer can reason about behavior from the tree alone.
Scattered inline `{{ config(...) }}` blocks are a maintenance smell — reach for one only
when a single model genuinely differs from its siblings.

## Checklist

- [ ] Config block (or intent comment) is the first thing in the file, followed by a blank line.
- [ ] CTEs read top-to-bottom in dependency order and each major block has a comment.
- [ ] Exactly one `final` CTE and one closing select.
- [ ] No `select *` except the closing line; every column is named.
- [ ] Every `ref()`/`source()` is aliased once, in `snake_case`.
- [ ] Repeated expressions were extracted to a macro or replaced with `dbt_utils`.
- [ ] No hardcoded environment values — `var()` / `env_var()` instead.
- [ ] Incremental models filter with `is_incremental()` so runs touch only new data.
