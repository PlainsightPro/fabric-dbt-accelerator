{{ config(unique_key='sales_rep_pk') }}

with sales_reps as (

    select * from {{ ref('stg_hr__sales_reps') }}

    {% if is_incremental() %}
        -- only re-process rows changed since the last run (full-refresh rebuilds everything) 
        where updated_at > (select coalesce(max(updated_at), '1900-01-01') from {{ this }}) -- noqa: RF02
    {% endif %}

),

final as (

    select
        sales_rep_pk,
        sales_rep_id,
        sales_rep_name,
        region,
        team_name as team_name_test_outcome,
        manager_name,
        updated_at,
        source_loaded_at,
        dbt_batch_id
    from sales_reps

)

select * from final
