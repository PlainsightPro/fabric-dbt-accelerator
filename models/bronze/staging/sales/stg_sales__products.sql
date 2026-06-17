{{ config(materialized='view') }}

WITH source_data AS (

    SELECT
        product_id,
        product_name,
        category_code,
        unit_price,
        active_from,
        active_to,
        updated_at,
        _loaded_at
    FROM {{ source('sales', 'raw_sales_products') }}

),

final AS (

    SELECT
        {{ hash_bigint(["'sales'", 'product_id']) }} AS product_pk,
        CAST(product_id AS VARCHAR(50)) AS product_id,
        CAST(product_name AS VARCHAR(200)) AS product_name,
        UPPER(CAST(category_code AS VARCHAR(50))) AS category_code,
        CAST(unit_price AS DECIMAL(18, 2)) AS unit_price,
        CAST(CAST(active_from AS VARCHAR(20)) AS DATE) AS active_from,
        CAST(NULLIF(CAST(active_to AS VARCHAR(20)), '') AS DATE) AS active_to,
        CAST(updated_at AS DATETIME2(6)) AS updated_at,
        CAST(_loaded_at AS DATETIME2(6)) AS source_loaded_at,
        'sales' AS source_system,
        SYSUTCDATETIME() AS dbt_loaded_at
    FROM source_data

)

SELECT
    product_pk,
    product_id,
    product_name,
    category_code,
    unit_price,
    active_from,
    active_to,
    updated_at,
    source_loaded_at,
    source_system,
    dbt_loaded_at
FROM final

