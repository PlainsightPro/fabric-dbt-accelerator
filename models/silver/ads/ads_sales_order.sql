{{ config(unique_key='sales_order_line_pk') }}

with orders as (

    select * from {{ ref('stg_sales__orders') }}

),

order_lines as (

    select * from {{ ref('stg_sales__order_lines') }}

    {% if is_incremental() %}
        -- only re-process lines changed since the last run (full-refresh rebuilds
        -- everything; a parent order header change that doesn't touch line
        -- updated_at, e.g. a status flip alone, won't retrigger its lines here)
        where updated_at > (select coalesce(max(order_line_updated_at), '1900-01-01') from {{ this }}) -- noqa: RF02
    {% endif %}

),

customers as (

    select * from {{ ref('ads_customer') }}

),

products as (

    select * from {{ ref('ads_product') }}

),

sales_reps as (

    select * from {{ ref('ads_sales_rep') }}

),

final as (

    select -- noqa: ST06
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
        order_lines.dbt_batch_id,
        orders.updated_at as order_updated_at,
        order_lines.updated_at as order_line_updated_at,
        coalesce(customers.customer_pk, 0) as customer_pk,
        coalesce(products.product_pk, 0) as product_pk,
        coalesce(products.product_category_pk, 0) as product_category_pk,
        coalesce(sales_reps.sales_rep_pk, 0) as sales_rep_pk,
        cast(convert(char(8), orders.order_date, 112) as int) as order_date_key,
        cast(
            (order_lines.quantity * order_lines.unit_price) - order_lines.discount_amount
            as decimal(18, 2)
        ) as net_sales_amount
    from order_lines
    inner join orders
        on order_lines.sales_order_pk = orders.sales_order_pk
    left join customers
        on orders.customer_id = customers.customer_id
    left join products
        on order_lines.product_id = products.product_id
    left join sales_reps
        on orders.sales_rep_id = sales_reps.sales_rep_id

)

select * from final
