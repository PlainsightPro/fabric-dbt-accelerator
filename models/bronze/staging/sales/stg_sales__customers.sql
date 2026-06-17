{{ config(materialized='view') }}

WITH source_data AS (

    SELECT
        customer_id,
        full_name,
        email,
        country_code,
        city,
        created_at,
        updated_at,
        _loaded_at
    FROM {{ source('sales', 'raw_sales_customers') }}

),

final AS (

    SELECT
        {{ hash_bigint(["'sales'", 'customer_id']) }} AS customer_pk,
        CAST(customer_id AS VARCHAR(50)) AS customer_id,
        CAST(full_name AS VARCHAR(200)) AS full_name,
        LOWER(CAST(email AS VARCHAR(320))) AS email,
        UPPER(CAST(country_code AS VARCHAR(2))) AS country_code,
        CAST(city AS VARCHAR(100)) AS city,
        CAST(created_at AS DATETIME2(6)) AS created_at,
        CAST(updated_at AS DATETIME2(6)) AS updated_at,
        CAST(_loaded_at AS DATETIME2(6)) AS source_loaded_at,
        'sales' AS source_system,
        SYSUTCDATETIME() AS dbt_loaded_at
    FROM source_data

)

SELECT
    customer_pk,
    customer_id,
    full_name,
    email,
    country_code,
    city,
    created_at,
    updated_at,
    source_loaded_at,
    source_system,
    dbt_loaded_at
FROM final

