{{ config(materialized='view') }}

WITH orders AS (

    SELECT
        sales_order_pk,
        order_id,
        customer_id,
        sales_rep_id,
        order_date,
        status,
        currency_code,
        updated_at,
        source_loaded_at
    FROM {{ ref('stg_sales__orders') }}

),

order_lines AS (

    SELECT
        sales_order_line_pk,
        sales_order_pk,
        order_id,
        line_id,
        product_id,
        quantity,
        unit_price,
        discount_amount,
        updated_at
    FROM {{ ref('stg_sales__order_lines') }}

),

customers AS (

    SELECT
        customer_pk,
        customer_id
    FROM {{ ref('ads_customer') }}

),

products AS (

    SELECT
        product_pk,
        product_id,
        product_category_pk,
        category_group
    FROM {{ ref('ads_product') }}

),

sales_reps AS (

    SELECT
        sales_rep_pk,
        sales_rep_id
    FROM {{ ref('ads_sales_rep') }}

),

final AS (

    SELECT -- noqa: ST06
        order_lines.sales_order_line_pk,
        orders.sales_order_pk,
        orders.order_id,
        order_lines.line_id,
        orders.order_date,
        orders.status,
        orders.currency_code,
        order_lines.quantity,
        order_lines.unit_price,
        order_lines.discount_amount,
        orders.source_loaded_at,
        orders.updated_at AS order_updated_at,
        order_lines.updated_at AS order_line_updated_at,
        COALESCE(customers.customer_pk, 0) AS customer_pk,
        COALESCE(products.product_pk, 0) AS product_pk,
        COALESCE(products.product_category_pk, 0) AS product_category_pk,
        COALESCE(sales_reps.sales_rep_pk, 0) AS sales_rep_pk,
        CAST(CONVERT(CHAR(8), orders.order_date, 112) AS INT) AS order_date_key,
        CAST(
            (order_lines.quantity * order_lines.unit_price) - order_lines.discount_amount
            AS DECIMAL(18, 2)
        ) AS net_sales_amount
    FROM order_lines
    INNER JOIN orders
        ON order_lines.sales_order_pk = orders.sales_order_pk
    LEFT JOIN customers
        ON orders.customer_id = customers.customer_id
    LEFT JOIN products
        ON order_lines.product_id = products.product_id
    LEFT JOIN sales_reps
        ON orders.sales_rep_id = sales_reps.sales_rep_id

)

SELECT
    sales_order_line_pk,
    sales_order_pk,
    customer_pk,
    product_pk,
    product_category_pk,
    sales_rep_pk,
    order_id,
    line_id,
    order_date,
    order_date_key,
    status,
    currency_code,
    quantity,
    unit_price,
    discount_amount,
    net_sales_amount,
    order_updated_at,
    order_line_updated_at,
    source_loaded_at
FROM final
