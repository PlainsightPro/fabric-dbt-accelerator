{{ config(materialized='table') }}

with source_data as (

    select * from {{ source('sales', 'raw_sales_orders') }}

),

final as (

    select
        {{ surrogate_key_bigint(["'sales'", 'order_id']) }} as sales_order_pk,
        cast(order_id as varchar(50)) as order_id,
        cast(customer_id as varchar(50)) as customer_id,
        cast(sales_rep_id as varchar(50)) as sales_rep_id,
        cast(order_date as date) as order_date,
        upper(cast(status as varchar(50))) as status,
        upper(cast(currency_code as varchar(3))) as currency_code,
        cast(updated_at as datetime2(6)) as updated_at,
        cast(_loaded_at as datetime2(6)) as source_loaded_at,
        {{ audit_column() }}
    from source_data

)

select * from final
