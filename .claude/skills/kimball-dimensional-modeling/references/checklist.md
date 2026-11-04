# Kimball Model Review Checklist

Run through this before signing off any Gold `fct_` or `dim_` model.

## All models

- [ ] Grain declared in `meta.grain` in `_models.yml`
- [ ] Primary key has `not_null` + `unique` tests
- [ ] Contract enforced, with `data_type` on every column
- [ ] Model description written for business users
- [ ] Column descriptions on all keys and measures
- [ ] No logic re-derived from ADS — Gold is a projection

## `dim_` models

- [ ] PK named `<entity>_key`, BIGINT, sourced from the ADS `_pk` (`surrogate_key_bigint`)
- [ ] Natural key retained under its source name
- [ ] Unknown member row with key `0` and `'UNKNOWN'` natural key
- [ ] No measures
- [ ] SCD type declared if any attribute can change; SCD 2 has `valid_from`, `valid_to`, `is_current`
- [ ] No existing conformed dim already covers this entity at this grain
- [ ] Hierarchies flattened into the dim unless snowflaking is justified

## `fct_` models

- [ ] Fact type stated (transaction, periodic snapshot, accumulating snapshot, factless)
- [ ] One grain only, with no fan-out from joins
- [ ] All dimension FKs are `_key` surrogate keys, never null (misses resolve to `0`)
- [ ] `relationships` test from every FK to its dim
- [ ] Measures additive, or semi/non-additive status documented
- [ ] No descriptive attributes, except documented degenerate dims
- [ ] Role-playing FKs have distinct, role-named columns

## Blocking issues (must fix before merging)

- Grain not declared
- Mixed grains in one fact
- Measure in a dim, or descriptive attribute in a fact
- Natural key or nullable FK in a fact
- Dim without a surrogate key or unknown member
- Mutable attribute with no declared SCD type
- Duplicate of an existing conformed dim
