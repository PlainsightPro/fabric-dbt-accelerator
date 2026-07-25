{#-
    Audit column stamped by every bronze staging model:
      dbt_batch_id - invocation_id of the dbt run that ingested this row,
                     carried through unchanged by silver/gold as a normal column

    Usage (as the last item in a final CTE's select list):
        select
            ...,
            cast(_loaded_at as datetime2(6)) as source_loaded_at,
            {{ audit_column() }}
        from source_data
-#}
{% macro audit_column() -%}
    cast('{{ invocation_id }}' as varchar(36)) as dbt_batch_id
{%- endmacro %}
