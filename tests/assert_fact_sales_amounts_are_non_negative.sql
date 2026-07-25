select
    sales_fact_key,
    net_sales_amount
from {{ ref('fact_sales') }}
where net_sales_amount < 0
