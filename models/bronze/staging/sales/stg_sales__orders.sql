{{ config(materialized='view') }}

WITH source_data AS (

    SELECT
        order_id,
        customer_id,
        sales_rep_id,
        order_date,
        status,
        currency_code,
        updated_at,
        _loaded_at
    FROM {{ source('sales', 'raw_sales_orders') }}

),

final AS (

    SELECT
        {{ hash_bigint(["'sales'", 'order_id']) }} AS sales_order_pk,
        CAST(order_id AS VARCHAR(50)) AS order_id,
        CAST(customer_id AS VARCHAR(50)) AS customer_id,
        CAST(sales_rep_id AS VARCHAR(50)) AS sales_rep_id,
        CAST(order_date AS DATE) AS order_date,
        UPPER(CAST(status AS VARCHAR(50))) AS status,
        UPPER(CAST(currency_code AS VARCHAR(3))) AS currency_code,
        CAST(updated_at AS DATETIME2(6)) AS updated_at,
        CAST(_loaded_at AS DATETIME2(6)) AS source_loaded_at,
        'sales' AS source_system,
        SYSUTCDATETIME() AS dbt_loaded_at
    FROM source_data

)

SELECT
    sales_order_pk,
    order_id,
    customer_id,
    sales_rep_id,
    order_date,
    status,
    currency_code,
    updated_at,
    source_loaded_at,
    source_system,
    dbt_loaded_at
FROM final

