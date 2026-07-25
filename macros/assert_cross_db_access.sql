{#-
    Slim CI smoke test: verifies that the current connection can read the
    given database via a cross-database three-part-name query. In Fabric this
    only works when both items live in the SAME workspace, which is exactly
    the prerequisite for deferring CI refs to the accept warehouse.

    Jinja cannot catch database exceptions, so the human-readable
    "colocate your workspaces" message lives in the CI workflow step that
    wraps this run-operation.

    Usage:
      dbt run-operation assert_cross_db_access --args '{database: WH_accept}' --target ci
-#}
{% macro assert_cross_db_access(database) %}
    {%- if not execute -%}{{ return('') }}{%- endif -%}

    {%- if not modules.re.match('^[A-Za-z0-9_ -]+$', database) -%}
        {{ exceptions.raise_compiler_error(
            "assert_cross_db_access: invalid database name '" ~ database ~ "'."
        ) }}
    {%- endif -%}

    {%- do run_query('SELECT TOP 1 1 FROM [' ~ database ~ '].INFORMATION_SCHEMA.TABLES') -%}
    {{ log("assert_cross_db_access: cross-database read of '" ~ database ~ "' succeeded.", info=True) }}
{% endmacro %}
