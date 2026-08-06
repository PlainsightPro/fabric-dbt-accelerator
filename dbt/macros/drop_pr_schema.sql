{#-
    Cleanup of PR-scoped CI schemas (pr_<PR number>, see generate_schema_name).

    Fabric Warehouse has no DROP SCHEMA ... CASCADE, so contained objects are
    dropped one by one before the schema itself. Run-operation macros use the
    profiles.yml connection, so the ci-cleanup pipelines need no extra tooling
    or credentials beyond what the build pipelines already have.

    Usage:
      dbt run-operation drop_pr_schema --args '{schema_name: pr_142}' --target ci
      dbt run-operation drop_all_pr_schemas --target ci   (scheduled sweep)
-#}

{% macro drop_pr_schema(schema_name) %}
    {%- if not execute -%}{{ return('') }}{%- endif -%}

    {#- Only ever drop PR schemas. Blocks real schemas (dbo, gold, ...) and,
        together with the strict pattern, any injection via the argument. -#}
    {%- if not modules.re.match('^pr_[0-9]+$', schema_name) -%}
        {{ exceptions.raise_compiler_error(
            "drop_pr_schema: refusing to drop '" ~ schema_name
            ~ "' - only schemas matching ^pr_[0-9]+$ may be dropped."
        ) }}
    {%- endif -%}

    {%- set schema_exists_query -%}
        SELECT schema_name
        FROM INFORMATION_SCHEMA.SCHEMATA
        WHERE schema_name = '{{ schema_name }}'
    {%- endset -%}
    {%- set schema_exists = run_query(schema_exists_query) -%}
    {%- if schema_exists.rows | length == 0 -%}
        {{ log("drop_pr_schema: schema '" ~ schema_name ~ "' does not exist - nothing to do.", info=True) }}
        {{ return('') }}
    {%- endif -%}

    {%- set objects_query -%}
        SELECT table_name, table_type
        FROM INFORMATION_SCHEMA.TABLES
        WHERE table_schema = '{{ schema_name }}'
    {%- endset -%}
    {%- set objects = run_query(objects_query) -%}
    {{ log("drop_pr_schema: dropping " ~ objects.rows | length ~ " object(s) in schema '" ~ schema_name ~ "'.", info=True) }}

    {%- for obj in objects.rows -%}
        {%- set drop_kind = 'VIEW' if obj['table_type'] == 'VIEW' else 'TABLE' -%}
        {{ log("drop_pr_schema: DROP " ~ drop_kind ~ " [" ~ schema_name ~ "].[" ~ obj['table_name'] ~ "]", info=True) }}
        {%- do run_query('DROP ' ~ drop_kind ~ ' [' ~ schema_name ~ '].[' ~ obj['table_name'] ~ ']') -%}
    {%- endfor -%}

    {%- do run_query('DROP SCHEMA [' ~ schema_name ~ ']') -%}
    {{ log("drop_pr_schema: schema '" ~ schema_name ~ "' dropped.", info=True) }}
{% endmacro %}


{#- Sweep used by the Azure DevOps cleanup pipeline (no PR-closed trigger
    there): drops every pr_<N> schema. Open PRs simply rebuild theirs on the
    next push - nothing reads pr_ schemas between CI runs. -#}
{% macro drop_all_pr_schemas() %}
    {%- if not execute -%}{{ return('') }}{%- endif -%}

    {%- set schemas_query -%}
        SELECT schema_name
        FROM INFORMATION_SCHEMA.SCHEMATA
        WHERE schema_name LIKE 'pr@_%' ESCAPE '@'
    {%- endset -%}
    {%- set schemas = run_query(schemas_query) -%}
    {%- set pr_schemas = [] -%}
    {%- for row in schemas.rows -%}
        {%- if modules.re.match('^pr_[0-9]+$', row['schema_name']) -%}
            {%- do pr_schemas.append(row['schema_name']) -%}
        {%- endif -%}
    {%- endfor -%}
    {{ log("drop_all_pr_schemas: found " ~ pr_schemas | length ~ " PR schema(s).", info=True) }}

    {%- for schema_name in pr_schemas -%}
        {{ drop_pr_schema(schema_name) }}
    {%- endfor -%}
{% endmacro %}
