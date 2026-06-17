{% macro hash_bigint(columns) -%}
    CONVERT(
        BIGINT,
        0x00 + SUBSTRING(
            HASHBYTES(
                'SHA2_256',
                CONCAT(
                    {%- for column in columns %}
                        COALESCE(CONVERT(VARCHAR(4000), {{ column }}), '__dbt_null__')
                        {%- if not loop.last %}, '||', {% endif -%}
                    {%- endfor %}
                )
            ),
            1,
            7
        )
    )
{%- endmacro %}
