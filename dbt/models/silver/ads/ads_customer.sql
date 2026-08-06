{{ config(unique_key='customer_pk') }}

with customers as (

    select * from {{ ref('stg_sales__customers') }}

    {% if is_incremental() %}
        -- only re-process rows changed since the last run (full-refresh rebuilds everything)
        where updated_at > (select coalesce(max(updated_at), '1900-01-01') from {{ this }}) -- noqa: RF02
    {% endif %}

),

final as (

    select
        customer_pk,
        customer_id,
        full_name,
        email,
        country_code,
        city,
        created_at,
        updated_at,
        source_loaded_at,
        dbt_batch_id,
        cast(
            case
                when country_code = 'BE' then 'Belgium'
                when country_code = 'NL' then 'Netherlands'
                when country_code = 'FR' then 'France'
                else 'Other'
            end as varchar(100)
        ) as country_name
    from customers

)

select * from final
