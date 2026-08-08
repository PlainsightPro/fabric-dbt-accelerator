{{ config(unique_key='product_pk') }}

with products as (

    select * from {{ ref('int_product_category_enriched') }}

    {% if is_incremental() %}
        -- only re-process rows changed since the last run (full-refresh rebuilds everything)
        where updated_at > (select coalesce(max(updated_at), '1900-01-01') from {{ this }}) -- noqa: RF02
    {% endif %}

),

final as (

    select
        product_pk,
        product_id,
        product_name,
        category_code,
        mdm_owner,
        unit_price,
        active_from,
        active_to,
        updated_at,
        source_loaded_at,
        dbt_batch_id,
        product_category_pk,
        category_name,
        category_group,
        is_budget_relevant,
        cast(case when active_to is null then 1 else 0 end as bit) as is_current
    from products

)

select * from final
