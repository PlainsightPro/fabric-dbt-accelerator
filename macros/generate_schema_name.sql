{#-
    Schema naming strategy per target:

    dev              -> <target.schema>_<custom_schema>, e.g. dev_jdoe_staging_sales.
                        Every developer gets a fully isolated set of schemas
                        (models AND seeds), keyed by the personal target.schema
                        defined in profiles.yml (dev_<username>).
    ci / accept / prod -> <custom_schema> as-is, e.g. staging_sales, ads, gold.
                        Falls back to target.schema when no custom schema is set.
-#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- elif target.name == 'dev' -%}
        {{ target.schema }}_{{ custom_schema_name | trim }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
