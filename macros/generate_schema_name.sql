{#-
    Schema naming strategy per target:

    ci (in a PR)     -> pr_<PR number>, e.g. pr_142. One flat schema per pull
                        request, keyed by DBT_CI_SCHEMA_SUFFIX (set by the CI
                        pipeline from the PR number). Isolates every PR build;
                        dropped again by the ci-cleanup pipeline on PR close.
                        When DBT_CI_SCHEMA_SUFFIX is unset/empty (local ci
                        runs, build-dev compile), falls through to the
                        default behavior below.
    dev              -> <target.schema>_<custom_schema>, e.g. dev_jdoe_staging_sales.
                        Every developer gets a fully isolated set of schemas
                        (models AND seeds), keyed by the personal target.schema
                        defined in profiles.yml (dev_<username>).
    ci / accept / prod -> <custom_schema> as-is, e.g. staging_sales, ads, gold.
                        Falls back to target.schema when no custom schema is set.
-#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if target.name == 'ci' and env_var('DBT_CI_SCHEMA_SUFFIX', '') | trim != '' -%}
        pr_{{ env_var('DBT_CI_SCHEMA_SUFFIX') | trim }}
    {%- elif custom_schema_name is none -%}
        {{ target.schema }}
    {%- elif target.name == 'dev' -%}
        {{ target.schema }}_{{ custom_schema_name | trim }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
