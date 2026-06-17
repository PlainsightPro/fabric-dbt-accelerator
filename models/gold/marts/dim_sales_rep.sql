{{ config(materialized='table') }}

WITH sales_reps AS (

    SELECT
        sales_rep_pk,
        sales_rep_id,
        sales_rep_name,
        region,
        team_name,
        manager_name,
        updated_at
    FROM {{ ref('ads_sales_rep') }}

),

unknown_member AS (

    SELECT
        CAST(0 AS BIGINT) AS sales_rep_key,
        CAST('UNKNOWN' AS VARCHAR(50)) AS sales_rep_id,
        CAST('Unknown sales rep' AS VARCHAR(200)) AS sales_rep_name,
        CAST('Unknown' AS VARCHAR(100)) AS region,
        CAST('Unknown' AS VARCHAR(100)) AS team_name,
        CAST('Unknown' AS VARCHAR(200)) AS manager_name,
        CAST(NULL AS DATETIME2(6)) AS updated_at

),

known_members AS (

    SELECT
        sales_rep_pk AS sales_rep_key,
        sales_rep_id,
        sales_rep_name,
        region,
        team_name,
        manager_name,
        updated_at
    FROM sales_reps

),

final AS (

    SELECT
        sales_rep_key,
        sales_rep_id,
        sales_rep_name,
        region,
        team_name,
        manager_name,
        updated_at
    FROM unknown_member

    UNION ALL

    SELECT
        sales_rep_key,
        sales_rep_id,
        sales_rep_name,
        region,
        team_name,
        manager_name,
        updated_at
    FROM known_members

)

SELECT
    sales_rep_key,
    sales_rep_id,
    sales_rep_name,
    region,
    team_name,
    manager_name,
    updated_at
FROM final

