with sales as (

    select * from {{ ref('ads_sales_order') }}
    where status <> 'CANCELLED'

),

final as (

    select
        sales_order_line_pk as sales_fact_key,
        sales_order_pk as sales_order_key,
        customer_pk as customer_key,
        product_pk as product_key,
        sales_rep_pk as sales_rep_key,
        order_date_key,
        order_id as order_number,
        line_id as order_line_number,
        status as order_status,
        currency_code,
        quantity,
        unit_price,
        discount_amount,
        net_sales_amount,
        order_updated_at,
        order_line_updated_at,
        dbt_batch_id
    from sales

)

select * from final
