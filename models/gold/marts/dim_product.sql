with products as (

    select * from {{ ref('ads_product') }}

),

unknown_member as (

    select
        cast(0 as bigint) as product_key,
        cast('UNKNOWN' as varchar(50)) as product_id,
        cast('Unknown product' as varchar(200)) as product_name,
        cast('UNKNOWN' as varchar(50)) as category_code,
        cast(0 as bigint) as product_category_key,
        cast('Unknown' as varchar(200)) as category_name,
        cast('Unknown' as varchar(200)) as category_group,
        cast(0 as bit) as is_budget_relevant,
        cast(null as decimal(18, 2)) as unit_price,
        cast(null as date) as active_from,
        cast(null as date) as active_to,
        cast(0 as bit) as is_current,
        cast(null as datetime2(6)) as updated_at,
        cast(null as varchar(36)) as dbt_batch_id

),

known_members as (

    select
        product_pk as product_key,
        product_id,
        product_name,
        category_code,
        product_category_pk as product_category_key,
        category_name,
        category_group,
        is_budget_relevant,
        unit_price,
        active_from,
        active_to,
        is_current,
        updated_at,
        dbt_batch_id
    from products

),

final as (

    select
        product_key,
        product_id,
        product_name,
        category_code,
        product_category_key,
        category_name,
        category_group,
        is_budget_relevant,
        unit_price,
        active_from,
        active_to,
        is_current,
        updated_at,
        dbt_batch_id
    from unknown_member

    union all

    select
        product_key,
        product_id,
        product_name,
        category_code,
        product_category_key,
        category_name,
        category_group,
        is_budget_relevant,
        unit_price,
        active_from,
        active_to,
        is_current,
        updated_at,
        dbt_batch_id
    from known_members

)

select * from final
