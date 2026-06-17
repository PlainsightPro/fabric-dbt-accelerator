{{ config(materialized='view') }}

WITH source_data AS (

    SELECT
        category_code,
        category_name,
        category_group,
        is_budget_relevant,
        mdm_owner,
        effective_from,
        effective_to,
        updated_at,
        _loaded_at
    FROM {{ source('master_data', 'mdm_product_category_mapping') }}

),

final AS (

    SELECT
        {{ hash_bigint(["'workbook_connect'", 'category_code']) }} AS product_category_pk,
        UPPER(CAST(category_code AS VARCHAR(50))) AS category_code,
        CAST(category_name AS VARCHAR(200)) AS category_name,
        CAST(category_group AS VARCHAR(200)) AS category_group,
        CAST(is_budget_relevant AS BIT) AS is_budget_relevant,
        CAST(mdm_owner AS VARCHAR(200)) AS mdm_owner,
        CAST(CAST(effective_from AS VARCHAR(20)) AS DATE) AS effective_from,
        CAST(NULLIF(CAST(effective_to AS VARCHAR(20)), '') AS DATE) AS effective_to,
        CAST(updated_at AS DATETIME2(6)) AS updated_at,
        CAST(_loaded_at AS DATETIME2(6)) AS source_loaded_at,
        'workbook_connect' AS source_system,
        SYSUTCDATETIME() AS dbt_loaded_at
    FROM source_data

)

SELECT
    product_category_pk,
    category_code,
    category_name,
    category_group,
    is_budget_relevant,
    mdm_owner,
    effective_from,
    effective_to,
    updated_at,
    source_loaded_at,
    source_system,
    dbt_loaded_at
FROM final

