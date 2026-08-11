with sales_reps as (

    select * from {{ ref('ads_sales_rep') }}

),

unknown_member as (

    select
        cast(0 as bigint) as sales_rep_key,
        cast('UNKNOWN' as varchar(50)) as sales_rep_id,
        cast('Unknown sales rep' as varchar(200)) as sales_rep_name,
        cast('Unknown' as varchar(100)) as region,
        cast('Unknown' as varchar(100)) as team_name,
        cast('Unknown' as varchar(200)) as manager_name,
        cast(null as datetime2(6)) as updated_at,
        cast(null as varchar(36)) as dbt_batch_id

),

known_members as (

    select
        sales_rep_pk as sales_rep_key,
        sales_rep_iddefrez,
        sales_rep_name,
        region,
        team_name,
        manager_name,
        updated_at,
        dbt_batch_id
    from sales_reps

),

final as (

    select
        sales_rep_key,
        sales_rep_id,
        sales_rep_name,
        region,
        team_name,
        manager_name,
        updated_at,
        dbt_batch_id
    from unknown_member

    union all

    select
        sales_rep_key,
        sales_rep_id,
        sales_rep_name,
        region,
        team_name,
        manager_name,
        updated_at,
        dbt_batch_id
    from known_members

)

select * from final
