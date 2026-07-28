with source_data as (

    select * from {{ source('sales', 'raw_sales_customers') }}

),

final as (

    select
        {{ surrogate_key_bigint(["'sales'", 'customer_id']) }} as customer_pk,
        cast(customer_id as varchar(50)) as customer_id,
        cast(full_name as varchar(200)) as full_name,
        lower(cast(email as varchar(320))) as email,
        upper(cast(country_code as varchar(2))) as country_code,
        cast(city as varchar(100)) as city,
        cast(created_at as datetime2(6)) as created_at,
        cast(updated_at as datetime2(6)) as updated_at,
        cast(_loaded_at as datetime2(6)) as source_loaded_at,
        {{ audit_column() }}
    from source_data

)

select * from final
