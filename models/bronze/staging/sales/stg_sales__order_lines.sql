{{ config(materialized='view') }}

WITH source_data AS (

    SELECT
        order_id,
        line_id,
        product_id,
        quantity,
        unit_price,
        discount_amount,
        updated_at,
        _loaded_at
    FROM {{ source('sales', 'raw_sales_order_lines') }}

),

final AS (

    SELECT
        {{ hash_bigint(["'sales'", 'order_id', 'line_id']) }} AS sales_order_line_pk,
        {{ hash_bigint(["'sales'", 'order_id']) }} AS sales_order_pk,
        CAST(order_id AS VARCHAR(50)) AS order_id,
        CAST(line_id AS INT) AS line_id,
        CAST(product_id AS VARCHAR(50)) AS product_id,
        CAST(quantity AS INT) AS quantity,
        CAST(unit_price AS DECIMAL(18, 2)) AS unit_price,
        CAST(discount_amount AS DECIMAL(18, 2)) AS discount_amount,
        CAST(updated_at AS DATETIME2(6)) AS updated_at,
        CAST(_loaded_at AS DATETIME2(6)) AS source_loaded_at,
        'sales' AS source_system,
        SYSUTCDATETIME() AS dbt_loaded_at
    FROM source_data

)

SELECT
    sales_order_line_pk,
    sales_order_pk,
    order_id,
    line_id,
    product_id,
    quantity,
    unit_price,
    discount_amount,
    updated_at,
    source_loaded_at,
    source_system,
    dbt_loaded_at
FROM final

