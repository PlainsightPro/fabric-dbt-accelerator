{#-
    Deterministic BIGINT surrogate key, built on dbt_utils.generate_surrogate_key.

    dbt_utils owns the key derivation itself (null sentinel, separator, casting,
    cross-adapter hashing); this macro only folds its 32-character MD5 hex string
    into a non-negative BIGINT, which is the key type every silver and gold model
    in this project expects.

    The fold re-hashes the surrogate key with SHA2_256 and keeps 7 bytes, prefixed
    with a zero byte so the value is never negative. Parsing the MD5 hex text into
    a number instead would rely on CONVERT(VARBINARY, ..., 1) style parsing; the
    HASHBYTES route is the conversion already proven against Fabric Warehouse here.
    56 bits of key space, so collisions stay negligible at the row counts these
    models carry.

    Usage (in a final CTE's select list):
        select
            {{ surrogate_key_bigint(["'sales'", 'customer_id']) }} as customer_pk,
            ...
-#}
{% macro surrogate_key_bigint(field_list) -%}
    convert(
        bigint,
        0x00 + substring(
            hashbytes('SHA2_256', {{ dbt_utils.generate_surrogate_key(field_list) }}),
            1,
            7
        )
    )
{%- endmacro %}
