with products as (

    select * from {{ ref('stg_sales__products') }}

),

categories as (

    select * from {{ ref('stg_mdm__product_category_mapping') }}

),

final as (

    select
        products.product_pk,
        products.product_id,
        products.product_name,
        products.category_code,
        categories.mdm_owner,
        products.unit_price,
        products.active_from,
        products.active_to,
        products.updated_at,
        products.source_loaded_at,
        products.dbt_batch_id,
        coalesce(categories.product_category_pk, 0) as product_category_pk,
        coalesce(categories.category_name, 'Unmapped') as category_name,
        coalesce(categories.category_group, 'Unmapped') as category_group,
        coalesce(categories.is_budget_relevant, cast(0 as bit)) as is_budget_relevant
    from products
    left join categories
        on products.category_code = categories.category_code

)

select * from final
