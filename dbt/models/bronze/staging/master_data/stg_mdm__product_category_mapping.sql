with source_data as (

    select * from {{ source('master_data', 'mdm_product_category_mapping') }}

),

final as (

    select
        {{ surrogate_key_bigint(["'workbook_connect'", 'category_code']) }} as product_category_pk,
        upper(cast(category_code as varchar(50))) as category_code,
        cast(category_name as varchar(200)) as category_name,
        cast(category_group as varchar(200)) as category_group,
        cast(is_budget_relevant as bit) as is_budget_relevant,
        cast(mdm_owner as varchar(200)) as mdm_owner,
        cast(cast(effective_from as varchar(20)) as date) as effective_from,
        cast(nullif(cast(effective_to as varchar(20)), '') as date) as effective_to,
        cast(updated_at as datetime2(6)) as updated_at,
        cast(_loaded_at as datetime2(6)) as source_loaded_at,
        {{ audit_column() }}
    from source_data

)

select * from final
