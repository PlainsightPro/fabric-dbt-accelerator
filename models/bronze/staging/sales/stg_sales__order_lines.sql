with source_data as (

    select * from {{ source('sales', 'raw_sales_order_lines') }}
    -- cost guard: on the ci target only, build against a recent slice of this
    -- line-grain source (renders to nothing on dev/accept/prod).
    {{ limit_ci_rows('updated_at', 30) }}

),

final as (

    select
        {{ hash_bigint(["'sales'", 'order_id', 'line_id']) }} as sales_order_line_pk,
        {{ hash_bigint(["'sales'", 'order_id']) }} as sales_order_pk,
        cast(order_id as varchar(50)) as order_id,
        cast(line_id as int) as line_id,
        cast(product_id as varchar(50)) as product_id,
        cast(quantity as int) as quantity,
        cast(unit_price as decimal(18, 2)) as unit_price,
        cast(discount_amount as decimal(18, 2)) as discount_amount,
        cast(updated_at as datetime2(6)) as updated_at,
        cast(_loaded_at as datetime2(6)) as source_loaded_at,
        {{ audit_column() }}
    from source_data

)

select * from final
