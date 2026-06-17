# Workbook Connect setup

Workbook Connect is used as the business-facing Master Data Tool in this accelerator.

## Demo table

The demo table is:

```text
mdm.mdm_product_category_mapping
```

It is initialized by:

```text
seeds/mdm/mdm_product_category_mapping.csv
```

## Intended workflow

1. Run `dbt seed` once to create the initial demo table.
2. Connect Workbook Connect to the Fabric Warehouse.
3. Configure Workbook Connect to expose `mdm.mdm_product_category_mapping`.
4. Give business owners permission to edit category mappings.
5. Business users maintain category names, groups, and flags in Excel.
6. dbt runs and consumes the table via the `master_data` source.

## Columns

| Column | Purpose | Editable by business? |
|---|---|---|
| `category_code` | Stable category code coming from source systems | No, key column |
| `category_name` | Business-friendly category name | Yes |
| `category_group` | Higher-level grouping for reporting | Yes |
| `is_budget_relevant` | Flag used by finance/planning logic | Yes |
| `mdm_owner` | Business owner of the mapping | Yes |
| `effective_from` | Start date of validity | Yes |
| `effective_to` | End date of validity | Yes |
| `updated_at` | Last update timestamp | System / controlled |
| `_loaded_at` | Technical load timestamp | System / controlled |

## Example DDL for a real Fabric Warehouse

Use this only if you are not using `dbt seed` to initialize the table.

```sql
CREATE SCHEMA mdm;

CREATE TABLE mdm.mdm_product_category_mapping (
    category_code NVARCHAR(50) NOT NULL,
    category_name NVARCHAR(200) NOT NULL,
    category_group NVARCHAR(200) NOT NULL,
    is_budget_relevant BIT NOT NULL,
    mdm_owner NVARCHAR(200) NOT NULL,
    effective_from DATE NOT NULL,
    effective_to DATE NULL,
    updated_at DATETIME2 NOT NULL,
    _loaded_at DATETIME2 NOT NULL
);
```

## Validation expectations

- `category_code` is unique and not null.
- Every Sales product category should map to exactly one active MDM category.
- `tests/assert_all_products_are_mapped_to_master_data.sql` fails when a product category is not mapped.
