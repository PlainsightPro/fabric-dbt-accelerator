{{ config(materialized='view') }}

WITH source_data AS (

    SELECT
        sales_rep_id,
        sales_rep_name,
        region,
        team_name,
        manager_name,
        updated_at,
        _loaded_at
    FROM {{ source('hr', 'raw_hr_sales_reps') }}

),

final AS (

    SELECT
        {{ hash_bigint(["'hr'", 'sales_rep_id']) }} AS sales_rep_pk,
        CAST(sales_rep_id AS VARCHAR(50)) AS sales_rep_id,
        CAST(sales_rep_name AS VARCHAR(200)) AS sales_rep_name,
        CAST(region AS VARCHAR(100)) AS region,
        CAST(team_name AS VARCHAR(100)) AS team_name,
        CAST(manager_name AS VARCHAR(200)) AS manager_name,
        CAST(updated_at AS DATETIME2(6)) AS updated_at,
        CAST(_loaded_at AS DATETIME2(6)) AS source_loaded_at,
        'hr' AS source_system,
        SYSUTCDATETIME() AS dbt_loaded_at
    FROM source_data

)

SELECT
    sales_rep_pk,
    sales_rep_id,
    sales_rep_name,
    region,
    team_name,
    manager_name,
    updated_at,
    source_loaded_at,
    source_system,
    dbt_loaded_at
FROM final

