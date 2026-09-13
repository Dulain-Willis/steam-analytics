{#
    Used in the dbt CI Github Actions workflow. When a PR is made a dbt 
    build run is executed as part of CI. This macro drops that schema 
    so it doesn't stick around. The db and schema are passedin as env 
    vars in the workflow code itself.
#}

{% macro drop_ci_schema() %}
    {% set drop_schema_sql %}
        drop schema if exists {{ target.database }}.{{ target.schema }}
    {% endset %}
   
    {% do run_query(drop_schema_sql) %}
    {{ log("Dropped schema " ~ target.schema, info=True) }}
{% endmacro %}
