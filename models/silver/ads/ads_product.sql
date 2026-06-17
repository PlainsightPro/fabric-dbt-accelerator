{{ config(materialized='view') }}

WITH products AS (

    SELECT
        product_pk,
        product_id,
        product_name,
        category_code,
        unit_price,
        active_from,
        active_to,
        updated_at,
        source_loaded_at
    FROM {{ ref('stg_sales__products') }}

),

categories AS (

    SELECT
        product_category_pk,
        category_code,
        category_name,
        category_group,
        is_budget_relevant,
        mdm_owner
    FROM {{ ref('stg_mdm__product_category_mapping') }}

),

final AS (

    SELECT
        products.product_pk,
        products.product_id,
        products.product_name,
        products.category_code,
        categories.mdm_owner,
        products.unit_price,
        products.active_from,
        products.active_to,
        products.updated_at,
        products.source_loaded_at,
        COALESCE(categories.product_category_pk, 0) AS product_category_pk,
        COALESCE(categories.category_name, 'Unmapped') AS category_name,
        COALESCE(categories.category_group, 'Unmapped') AS category_group,
        COALESCE(categories.is_budget_relevant, 0) AS is_budget_relevant,
        CASE WHEN products.active_to IS NULL THEN 1 ELSE 0 END AS is_current
    FROM products
    LEFT JOIN categories
        ON products.category_code = categories.category_code

)

SELECT
    product_pk,
    product_id,
    product_name,
    category_code,
    product_category_pk,
    category_name,
    category_group,
    is_budget_relevant,
    mdm_owner,
    unit_price,
    active_from,
    active_to,
    is_current,
    updated_at,
    source_loaded_at
FROM final
