with source_data as (

    select * from {{ source('hr', 'raw_hr_sales_reps') }}

),

final as (

    select
        {{ surrogate_key_bigint(["'hr'", 'sales_rep_id']) }} as sales_rep_pk,
        cast(sales_rep_id as varchar(50)) as sales_rep_id,
        cast(sales_rep_name as varchar(200)) as sales_rep_name,
        cast(region as varchar(100)) as region,
        cast(team_name as varchar(100)) as team_name,
        cast(manager_name as varchar(200)) as manager_name,
        cast(updated_at as datetime2(6)) as updated_at,
        cast(_loaded_at as datetime2(6)) as source_loaded_at,
        {{ audit_column() }}
    from source_data

)

select * from final
