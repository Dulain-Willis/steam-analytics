{{
    config(
        materialized='incremental',
        unique_key=['schema_name', 'table_name', 'snapshot_date'],
        incremental_strategy='merge',
    )
}}

with information_schema_tables as (

    select
        table_schema as schema_name,
        table_name,
        row_count,
        current_date() as snapshot_date

    from information_schema.tables

    where
        table_type = 'BASE TABLE'
        and table_schema != 'ELEMENTARY'

),

final as (

    select
        schema_name,
        table_name,
        snapshot_date,
        row_count

    from information_schema_tables

)

select * from final
