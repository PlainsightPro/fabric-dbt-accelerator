{{ config(materialized='table') }}

WITH sales AS (

    SELECT
        sales_order_line_pk,
        sales_order_pk,
        customer_pk,
        product_pk,
        sales_rep_pk,
        order_id,
        line_id,
        order_date_key,
        status,
        currency_code,
        quantity,
        unit_price,
        discount_amount,
        net_sales_amount,
        order_updated_at,
        order_line_updated_at
    FROM {{ ref('ads_sales_order') }}
    WHERE status <> 'CANCELLED'

),

final AS (

    SELECT
        sales_order_line_pk AS sales_fact_key,
        sales_order_pk AS sales_order_key,
        customer_pk AS customer_key,
        product_pk AS product_key,
        sales_rep_pk AS sales_rep_key,
        order_date_key,
        order_id AS order_number,
        line_id AS order_line_number,
        status AS order_status,
        currency_code,
        quantity,
        unit_price,
        discount_amount,
        net_sales_amount,
        order_updated_at,
        order_line_updated_at
    FROM sales

)

SELECT
    sales_fact_key,
    sales_order_key,
    customer_key,
    product_key,
    sales_rep_key,
    order_date_key,
    order_number,
    order_line_number,
    order_status,
    currency_code,
    quantity,
    unit_price,
    discount_amount,
    net_sales_amount,
    order_updated_at,
    order_line_updated_at
FROM final
