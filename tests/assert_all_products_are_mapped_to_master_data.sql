SELECT
    product_id,
    category_code
FROM {{ ref('ads_product') }}
WHERE product_category_pk = 0
