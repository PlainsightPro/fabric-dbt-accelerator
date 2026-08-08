with source_data as (

    select * from {{ source('sales', 'raw_sales_products') }}

),

final as (

    select
        {{ surrogate_key_bigint(["'sales'", 'product_id']) }} as product_pk,
        cast(product_id as varchar(50)) as product_id,
        cast(product_name as varchar(200)) as product_name,
        upper(cast(category_code as varchar(50))) as category_code,
        cast(unit_price as decimal(18, 2)) as unit_price,
        cast(cast(active_from as varchar(20)) as date) as active_from,
        cast(nullif(cast(active_to as varchar(20)), '') as date) as active_to,
        cast(updated_at as datetime2(6)) as updated_at,
        cast(_loaded_at as datetime2(6)) as source_loaded_at,
        {{ audit_column() }}
    from source_data

)

select * from final
