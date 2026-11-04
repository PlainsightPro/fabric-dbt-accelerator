{#-
    Deterministic, case-insensitive BIGINT surrogate key.

    Hashes the natural key once with SHA2_256 and folds the digest into a
    non-negative BIGINT, which is the key type every silver and gold model in
    this project expects.

    Field normalisation is owned here rather than delegated to
    dbt_utils.generate_surrogate_key. Three reasons:

      - dbt_utils returns its digest as hex TEXT, and BIGINT can only be built
        from binary. Getting back to binary meant either re-hashing that text
        (a second HASHBYTES used purely as a type conversion) or parsing it with
        CONVERT(VARBINARY, ..., 1). Hashing once needs neither - HASHBYTES
        already returns varbinary.
      - it was this project's only package dependency, and packages.yml floated
        the version range. A dbt_utils release that changed its normalisation
        would have silently rotated every key in the warehouse: no error, no
        failing test, just different numbers.
      - the compiled SQL is one expression instead of four nested macro layers.

    Normalisation rules. Changing ANY of them changes every key value and
    requires rebuilding every model that stores one:

      - each field is cast to varchar(8000), then UPPER, so 'abc' and 'ABC'
        produce the same key. Note the trade-off this accepts: two natural keys
        that differ only in case are treated as ONE entity. That is the right
        call for the business keys here (product/category codes maintained by
        hand), but it would be wrong for a genuinely case-sensitive identifier.
      - fields are joined with '-' so ('ab','c') cannot collide with ('a','bc').
      - NULL becomes a sentinel so (NULL,'a') cannot collide with ('','a').

    The fold keeps 7 bytes of the digest prefixed with a zero byte, so the value
    is never negative. 56 bits of key space, so collisions stay negligible at
    the row counts these models carry.

    Usage (in a final CTE's select list):
        select
            {{ surrogate_key_bigint(["'sales'", 'customer_id']) }} as customer_pk,
            ...
-#}
{% macro surrogate_key_bigint(field_list) -%}
    {%- set parts = [] -%}
    {%- for field in field_list -%}
        {%- do parts.append(
            "coalesce(upper(cast(" ~ field ~ " as varchar(8000))), '_surrogate_key_null_')"
        ) -%}
        {%- if not loop.last -%}
            {%- do parts.append("'-'") -%}
        {%- endif -%}
    {%- endfor -%}
    {#- T-SQL concat() requires at least two arguments. -#}
    {%- set key_input = parts[0] if parts | length < 2 else 'concat(' ~ parts | join(', ') ~ ')' -%}
    convert(
        bigint,
        0x00 + substring(
            hashbytes('SHA2_256', {{ key_input }}),
            1,
            7
        )
    )
{%- endmacro %}
