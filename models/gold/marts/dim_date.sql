{{ config(materialized='table') }}

WITH order_dates AS (

    SELECT order_date
    FROM {{ ref('ads_sales_order') }}
    GROUP BY order_date

),

final AS (

    SELECT -- noqa: ST06
        order_date,
        CAST(CONVERT(CHAR(8), order_date, 112) AS INT) AS date_key,
        DATEPART(YEAR, order_date) AS calendar_year,
        DATEPART(QUARTER, order_date) AS calendar_quarter,
        DATEPART(MONTH, order_date) AS month_number,
        CAST(DATENAME(MONTH, order_date) AS VARCHAR(50)) AS month_name,
        DATEPART(DAY, order_date) AS day_of_month,
        DATEPART(ISO_WEEK, order_date) AS iso_week_number
    FROM order_dates

)

SELECT
    date_key,
    order_date AS date_value,
    calendar_year,
    calendar_quarter,
    month_number,
    month_name,
    day_of_month,
    iso_week_number
FROM final

