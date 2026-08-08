with customers as (

    select * from {{ ref('ads_customer') }}

),

unknown_member as (

    select
        cast(0 as bigint) as customer_key,
        cast('UNKNOWN' as varchar(50)) as customer_id,
        cast('Unknown customer' as varchar(200)) as full_name,
        cast(null as varchar(320)) as email,
        cast(null as varchar(2)) as country_code,
        cast('Unknown' as varchar(100)) as country_name,
        cast('Unknown' as varchar(100)) as city,
        cast(null as datetime2(6)) as created_at,
        cast(null as datetime2(6)) as updated_at,
        cast(null as varchar(36)) as dbt_batch_id

),

known_members as (

    select
        customer_pk as customer_key,
        customer_id,
        full_name,
        email,
        country_code,
        country_name,
        city,
        created_at,
        updated_at,
        dbt_batch_id
    from customers

),

final as (

    select
        customer_key,
        customer_id,
        full_name,
        email,
        country_code,
        country_name,
        city,
        created_at,
        updated_at,
        dbt_batch_id
    from unknown_member

    union all

    select
        customer_key,
        customer_id,
        full_name,
        email,
        country_code,
        country_name,
        city,
        created_at,
        updated_at,
        dbt_batch_id
    from known_members

)

select * from final
