{#-
    Cost guard for slim CI: emits a WHERE clause restricting a model to the
    last <days> days, but ONLY when running against the ci target. On every
    other target (and under sqlfluff, where `target` is undefined) it renders
    to nothing, so accept/prod compiled SQL is byte-identical.

    Apply it to large child/fact-grain models only (never to the parent side
    of a relationships test - a filtered parent would orphan child rows and
    fail the test). Example: models/bronze/staging/sales/stg_sales__order_lines.sql.

    Usage (in place of a WHERE clause on the source CTE):
        FROM {{ source('sales', 'raw_sales_order_lines') }}
        {{ limit_ci_rows('updated_at', 30) }}
-#}
{% macro limit_ci_rows(column, days=30) %}
    {%- if target is defined and target.name == 'ci' -%}
        WHERE {{ column }} >= DATEADD(DAY, -{{ days }}, SYSUTCDATETIME())
    {%- endif -%}
{% endmacro %}
