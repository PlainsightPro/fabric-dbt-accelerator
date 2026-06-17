{{ config(materialized='view') }}

WITH customers AS (

    SELECT
        customer_pk,
        customer_id,
        full_name,
        email,
        country_code,
        city,
        created_at,
        updated_at,
        source_loaded_at
    FROM {{ ref('stg_sales__customers') }}

),

final AS (

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
        CASE
            WHEN country_code = 'BE' THEN 'Belgium'
            WHEN country_code = 'NL' THEN 'Netherlands'
            WHEN country_code = 'FR' THEN 'France'
            ELSE 'Other'
        END AS country_name
    FROM customers

)

SELECT
    customer_pk,
    customer_id,
    full_name,
    email,
    country_code,
    country_name,
    city,
    created_at,
    updated_at,
    source_loaded_at
FROM final
