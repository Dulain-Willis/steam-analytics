{#
    Custom schema naming: the schema is the folder-derived name verbatim in
    every environment (no target/env prefix), so the warehouse layout mirrors
    the repo. Each layer folder sets its own `+schema` in dbt_project.yml:

        staging          -> stg
        intermediate     -> int
        marts/core       -> marts_core
        marts/product    -> marts_product
        marts/marketing  -> marts_marketing
        marts/finance    -> marts_finance
        elementary pkg   -> elementary

    Models without a `+schema` config fall back to the target's default schema.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}
