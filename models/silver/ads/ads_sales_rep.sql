{{ config(materialized='view') }}

WITH sales_reps AS (

    SELECT
        sales_rep_pk,
        sales_rep_id,
        sales_rep_name,
        region,
        team_name,
        manager_name,
        updated_at,
        source_loaded_at
    FROM {{ ref('stg_hr__sales_reps') }}

),

final AS (

    SELECT
        sales_rep_pk,
        sales_rep_id,
        sales_rep_name,
        region,
        team_name,
        manager_name,
        updated_at,
        source_loaded_at
    FROM sales_reps

)

SELECT
    sales_rep_pk,
    sales_rep_id,
    sales_rep_name,
    region,
    team_name,
    manager_name,
    updated_at,
    source_loaded_at
FROM final
