{{ config(materialized='table') }}

WITH products AS (

    SELECT
        product_pk,
        product_id,
        product_name,
        category_code,
        product_category_pk,
        category_name,
        category_group,
        is_budget_relevant,
        unit_price,
        active_from,
        active_to,
        is_current,
        updated_at
    FROM {{ ref('ads_product') }}

),

unknown_member AS (

    SELECT
        CAST(0 AS BIGINT) AS product_key,
        CAST('UNKNOWN' AS VARCHAR(50)) AS product_id,
        CAST('Unknown product' AS VARCHAR(200)) AS product_name,
        CAST('UNKNOWN' AS VARCHAR(50)) AS category_code,
        CAST(0 AS BIGINT) AS product_category_key,
        CAST('Unknown' AS VARCHAR(200)) AS category_name,
        CAST('Unknown' AS VARCHAR(200)) AS category_group,
        CAST(0 AS BIT) AS is_budget_relevant,
        CAST(NULL AS DECIMAL(18, 2)) AS unit_price,
        CAST(NULL AS DATE) AS active_from,
        CAST(NULL AS DATE) AS active_to,
        CAST(0 AS BIT) AS is_current,
        CAST(NULL AS DATETIME2(6)) AS updated_at

),

known_members AS (

    SELECT
        product_pk AS product_key,
        product_id,
        product_name,
        category_code,
        product_category_pk AS product_category_key,
        category_name,
        category_group,
        is_budget_relevant,
        unit_price,
        active_from,
        active_to,
        is_current,
        updated_at
    FROM products

),

final AS (

    SELECT
        product_key,
        product_id,
        product_name,
        category_code,
        product_category_key,
        category_name,
        category_group,
        is_budget_relevant,
        unit_price,
        active_from,
        active_to,
        is_current,
        updated_at
    FROM unknown_member

    UNION ALL

    SELECT
        product_key,
        product_id,
        product_name,
        category_code,
        product_category_key,
        category_name,
        category_group,
        is_budget_relevant,
        unit_price,
        active_from,
        active_to,
        is_current,
        updated_at
    FROM known_members

)

SELECT
    product_key,
    product_id,
    product_name,
    category_code,
    product_category_key,
    category_name,
    category_group,
    is_budget_relevant,
    unit_price,
    active_from,
    active_to,
    is_current,
    updated_at
FROM final

