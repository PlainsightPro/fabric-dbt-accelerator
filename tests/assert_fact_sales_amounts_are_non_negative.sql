SELECT
    sales_fact_key,
    net_sales_amount
FROM {{ ref('fact_sales') }}
WHERE net_sales_amount < 0
