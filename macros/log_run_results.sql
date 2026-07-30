{#-
    Run-result logging, wired as the project's on-run-end hook.

    Persists what dbt just did into a two-table star schema in the warehouse, so
    an unattended run leaves a trail that outlives the console output. This
    matters most on accept/prod: those targets are executed by the Fabric
    runtime on its own schedule, not by a CI pipeline, so there is no build log
    to go back to.

      <schema>.dim_dbt_nodes - one row per dbt node (SCD type 1)
      <schema>.fct_dbt_runs  - one row per node per invocation

    sk_dbt_node is a deterministic surrogate_key_bigint of the node's unique_id,
    derived identically on both sides, so the fact never needs a dimension
    lookup and can never orphan.

    Gating (both overridable per run, which is how you test it locally):
      dbt_run_log_targets - targets that log at all. Default ['accept', 'prod'];
                            dev and ci write nothing.
      dbt_run_log_schema  - schema holding the two tables. Default 'meta'.

    The tables are created on first use - accept/prod have no migration step.

    Fires on dbt build/run/test/seed/snapshot. NOT on dbt compile, which is what
    the deploy pipelines run, so deploying the project never writes to prod.

    All timestamps are UTC.

    Usage (dbt_project.yml):
        on-run-end:
          - "{{ log_run_results(results) }}"

    Usage (exercise it against your own dev schema):
        dbt build --target dev \
          --vars '{dbt_run_log_targets: [dev], dbt_run_log_schema: dev_jdoe_meta}'
-#}

{% macro log_run_results(results) %}
    {%- if not execute or not results or not should_log_run_results() -%}
        {{ return('') }}
    {%- endif -%}

    {%- set log_schema = var('dbt_run_log_schema', 'meta') -%}
    {%- set logged_at = run_log_timestamp(modules.datetime.datetime.now(modules.pytz.UTC)) -%}
    {%- set run_started = run_log_timestamp(run_started_at) -%}

    {%- do ensure_run_log_tables(log_schema) -%}

    {#- dim_rows and fct_rows stay index-aligned so a chunk can be sliced from both. -#}
    {%- set dim_rows = [] -%}
    {%- set fct_rows = [] -%}

    {%- for res in results -%}
        {%- if res.node is defined -%}
            {%- set node = res.node -%}
            {%- set status = res.status | string | lower -%}

            {#- Exact phase boundaries from the result itself, so the fact does not
                have to reconstruct a start time by subtracting the duration. -#}
            {%- set execute_timing = (res.timing | selectattr('name', 'equalto', 'execute') | list | first)
                    | default(none, true) -%}
            {%- set compile_timing = (res.timing | selectattr('name', 'equalto', 'compile') | list | first)
                    | default(none, true) -%}
            {%- set timing = execute_timing if execute_timing else compile_timing -%}

            {#- adapter_response is a plain dict in the artifact schema but an
                AdapterResponse object at runtime; handle both. -#}
            {%- set adapter_response = res.adapter_response | default({}, true) -%}
            {%- if adapter_response is mapping -%}
                {%- set rows_affected = adapter_response.get('rows_affected', 0) -%}
            {%- else -%}
                {%- set rows_affected = adapter_response.rows_affected | default(0, true) -%}
            {%- endif -%}

            {%- do dim_rows.append([
                node.unique_id,
                node.name,
                node.resource_type | string,
                node.config.materialized | default(none, true),
                node.package_name,
                node.database,
                node.schema,
                node.original_file_path | default(none, true),
                logged_at
            ]) -%}

            {%- do fct_rows.append([
                invocation_id,
                node.unique_id,
                run_started,
                target.name,
                flags.WHICH | string,
                run_log_timestamp(timing.started_at if timing else none),
                run_log_timestamp(timing.completed_at if timing else none),
                res.execution_time | default(0, true) | round(3),
                status,
                1 if status in ['success', 'pass'] else 0,
                1 if status in ['error', 'fail', 'runtime error'] else 0,
                1 if status == 'skipped' else 0,
                rows_affected,
                res.failures,
                (res.message | default('', true) | string)[:4000],
                logged_at
            ]) -%}
        {%- endif -%}
    {%- endfor -%}

    {%- if fct_rows | length == 0 -%}
        {{ return('') }}
    {%- endif -%}

    {#- 16 bound values per fact row; calc_batch_size applies the adapter's own
        2100-parameter-per-statement rule (dbt-fabric seed helpers). -#}
    {%- set batch_size = calc_batch_size(16) -%}

    {%- for offset in range(0, fct_rows | length, batch_size) -%}
        {%- do write_run_log_chunk(
            log_schema,
            dim_rows[offset:offset + batch_size],
            fct_rows[offset:offset + batch_size]
        ) -%}
    {%- endfor -%}

    {{ log(
        "log_run_results: logged " ~ fct_rows | length ~ " node result(s) to ["
        ~ log_schema ~ "].[fct_dbt_runs].", info=True
    ) }}
    {{ return('') }}
{% endmacro %}


{#- Targets that write a run log. Everything else no-ops. -#}
{% macro should_log_run_results() %}
    {{ return(target.name in var('dbt_run_log_targets', ['accept', 'prod'])) }}
{% endmacro %}


{#- datetime -> a literal T-SQL accepts for DATETIME2(6), or none.

    Formatted here rather than left to the adapter's isoformat() conversion:
    run_started_at is timezone-aware, and its "+00:00" offset does not parse as
    DATETIME2. Dropping the offset is safe - every timestamp logged is UTC. -#}
{% macro run_log_timestamp(value) %}
    {%- if value is none -%}
        {{ return(none) }}
    {%- endif -%}
    {{ return(value.strftime('%Y-%m-%d %H:%M:%S.%f')) }}
{% endmacro %}


{#- Creates the log schema and both tables when they are missing. Accept and prod
    are deployed as project code with no migration step, so the first scheduled
    run has to be able to bootstrap its own target. -#}
{% macro ensure_run_log_tables(log_schema) %}
    {%- do adapter.create_schema(api.Relation.create(database=target.database, schema=log_schema)) -%}

    {%- set dim_ddl -%}
        CREATE TABLE [{{ log_schema }}].[dim_dbt_nodes] (
            sk_dbt_node BIGINT NOT NULL,
            dk_dbt_node VARCHAR(500) NOT NULL,
            node_name VARCHAR(250) NULL,
            resource_type VARCHAR(50) NULL,
            materialization VARCHAR(50) NULL,
            node_package VARCHAR(250) NULL,
            node_database VARCHAR(128) NULL,
            node_schema VARCHAR(128) NULL,
            node_path VARCHAR(500) NULL,
            first_seen_at DATETIME2(6) NULL,
            last_seen_at DATETIME2(6) NULL
        )
    {%- endset -%}

    {%- set fct_ddl -%}
        CREATE TABLE [{{ log_schema }}].[fct_dbt_runs] (
            invocation_id VARCHAR(36) NOT NULL,
            sk_dbt_node BIGINT NOT NULL,
            run_started_at DATETIME2(6) NULL,
            target_name VARCHAR(50) NULL,
            dbt_command VARCHAR(50) NULL,
            execution_started_at DATETIME2(6) NULL,
            execution_ended_at DATETIME2(6) NULL,
            execution_seconds DECIMAL(18, 3) NULL,
            status VARCHAR(20) NULL,
            is_success BIT NULL,
            is_error BIT NULL,
            is_skipped BIT NULL,
            rows_affected BIGINT NULL,
            failures INT NULL,
            [message] VARCHAR(4000) NULL,
            logged_at DATETIME2(6) NULL
        )
    {%- endset -%}

    {%- do create_run_log_table_if_missing(log_schema, 'dim_dbt_nodes', dim_ddl) -%}
    {%- do create_run_log_table_if_missing(log_schema, 'fct_dbt_runs', fct_ddl) -%}
{% endmacro %}


{#- Probe first and branch in Jinja rather than wrapping CREATE TABLE in a T-SQL
    IF block - same shape as drop_pr_schema. -#}
{% macro create_run_log_table_if_missing(log_schema, table_name, create_sql) %}
    {%- set table_exists_query -%}
        SELECT table_name
        FROM INFORMATION_SCHEMA.TABLES
        WHERE table_schema = '{{ log_schema }}'
          AND table_name = '{{ table_name }}'
    {%- endset -%}

    {%- if run_query(table_exists_query).rows | length == 0 -%}
        {{ log("log_run_results: creating [" ~ log_schema ~ "].[" ~ table_name ~ "].", info=True) }}
        {%- do run_query(create_sql) -%}
    {%- endif -%}
{% endmacro %}


{#- Writes one batch: refresh the dimension, insert nodes seen for the first
    time, then append the facts. Values are bound as parameters (never
    interpolated), so no message text can break or inject into the statement.

    No enclosing transaction: on-run-end deliberately runs outside one, and a
    partially written log beats a hook failure that marks a green run red. -#}
{% macro write_run_log_chunk(log_schema, dim_chunk, fct_chunk) %}
    {%- set dim_columns = '(dk_dbt_node, node_name, resource_type, materialization, node_package,'
            ~ ' node_database, node_schema, node_path, observed_at)' -%}
    {%- set dim_placeholders = '(CAST(? AS VARCHAR(500)), CAST(? AS VARCHAR(250)), CAST(? AS VARCHAR(50)),'
            ~ ' CAST(? AS VARCHAR(50)), CAST(? AS VARCHAR(250)), CAST(? AS VARCHAR(128)),'
            ~ ' CAST(? AS VARCHAR(128)), CAST(? AS VARCHAR(500)), CAST(? AS DATETIME2(6)))' -%}

    {%- set fct_columns = '(invocation_id, dk_dbt_node, run_started_at, target_name, dbt_command,'
            ~ ' execution_started_at, execution_ended_at, execution_seconds, status, is_success,'
            ~ ' is_error, is_skipped, rows_affected, failures, [message], logged_at)' -%}
    {%- set fct_placeholders = '(CAST(? AS VARCHAR(36)), CAST(? AS VARCHAR(500)), CAST(? AS DATETIME2(6)),'
            ~ ' CAST(? AS VARCHAR(50)), CAST(? AS VARCHAR(50)), CAST(? AS DATETIME2(6)),'
            ~ ' CAST(? AS DATETIME2(6)), CAST(? AS DECIMAL(18, 3)), CAST(? AS VARCHAR(20)),'
            ~ ' CAST(? AS BIT), CAST(? AS BIT), CAST(? AS BIT), CAST(? AS BIGINT), CAST(? AS INT),'
            ~ ' CAST(? AS VARCHAR(4000)), CAST(? AS DATETIME2(6)))' -%}

    {%- set dim_bindings = [] -%}
    {%- for row in dim_chunk -%}
        {%- do dim_bindings.extend(row) -%}
    {%- endfor -%}
    {%- set dim_values = ([dim_placeholders] * (dim_chunk | length)) | join(',\n            ') -%}

    {%- set fct_bindings = [] -%}
    {%- for row in fct_chunk -%}
        {%- do fct_bindings.extend(row) -%}
    {%- endfor -%}
    {%- set fct_values = ([fct_placeholders] * (fct_chunk | length)) | join(',\n            ') -%}

    {#- SCD type 1: a node whose materialization or schema changed is corrected
        in place, and last_seen_at moves on every run. -#}
    {%- set dim_update -%}
        UPDATE d
        SET
            node_name = s.node_name,
            resource_type = s.resource_type,
            materialization = s.materialization,
            node_package = s.node_package,
            node_database = s.node_database,
            node_schema = s.node_schema,
            node_path = s.node_path,
            last_seen_at = s.observed_at
        FROM [{{ log_schema }}].[dim_dbt_nodes] AS d
        INNER JOIN (VALUES
            {{ dim_values }}
        ) AS s {{ dim_columns }}
            ON d.dk_dbt_node = s.dk_dbt_node
    {%- endset -%}

    {%- set dim_insert -%}
        INSERT INTO [{{ log_schema }}].[dim_dbt_nodes] (
            sk_dbt_node,
            dk_dbt_node,
            node_name,
            resource_type,
            materialization,
            node_package,
            node_database,
            node_schema,
            node_path,
            first_seen_at,
            last_seen_at
        )
        SELECT
            {{ surrogate_key_bigint(['s.dk_dbt_node']) }},
            s.dk_dbt_node,
            s.node_name,
            s.resource_type,
            s.materialization,
            s.node_package,
            s.node_database,
            s.node_schema,
            s.node_path,
            s.observed_at,
            s.observed_at
        FROM (VALUES
            {{ dim_values }}
        ) AS s {{ dim_columns }}
        WHERE NOT EXISTS (
            SELECT 1
            FROM [{{ log_schema }}].[dim_dbt_nodes] AS d
            WHERE d.dk_dbt_node = s.dk_dbt_node
        )
    {%- endset -%}

    {%- set fct_insert -%}
        INSERT INTO [{{ log_schema }}].[fct_dbt_runs] (
            invocation_id,
            sk_dbt_node,
            run_started_at,
            target_name,
            dbt_command,
            execution_started_at,
            execution_ended_at,
            execution_seconds,
            status,
            is_success,
            is_error,
            is_skipped,
            rows_affected,
            failures,
            [message],
            logged_at
        )
        SELECT
            s.invocation_id,
            {{ surrogate_key_bigint(['s.dk_dbt_node']) }},
            s.run_started_at,
            s.target_name,
            s.dbt_command,
            s.execution_started_at,
            s.execution_ended_at,
            s.execution_seconds,
            s.status,
            s.is_success,
            s.is_error,
            s.is_skipped,
            s.rows_affected,
            s.failures,
            s.[message],
            s.logged_at
        FROM (VALUES
            {{ fct_values }}
        ) AS s {{ fct_columns }}
    {%- endset -%}

    {%- do adapter.add_query(dim_update, auto_begin=False, bindings=dim_bindings, abridge_sql_log=True) -%}
    {%- do adapter.add_query(dim_insert, auto_begin=False, bindings=dim_bindings, abridge_sql_log=True) -%}
    {%- do adapter.add_query(fct_insert, auto_begin=False, bindings=fct_bindings, abridge_sql_log=True) -%}
{% endmacro %}
