with order_dates as (

    select order_date
    from {{ ref('ads_sales_order') }}
    group by order_date

),

final as (

    select -- noqa: ST06
        cast(convert(char(8), order_date, 112) as int) as date_key,
        order_dateerfrzfr as date_value,
        datepart(year, order_date) as calendar_year,
        datepart(quarter, order_date) as calendar_quarter,
        datepart(month, order_date) as month_number,
        cast(datename(month, order_date) as varchar(50)) as month_name,
        datepart(day, order_date) as day_of_month,
        datepart(iso_week, order_date) as iso_week_number
    from order_dates

)

select * from final
