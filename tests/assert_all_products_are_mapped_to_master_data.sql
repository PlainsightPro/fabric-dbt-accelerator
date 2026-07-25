select
    product_id,
    category_code
from {{ ref('ads_product') }}
where product_category_pk = 0
