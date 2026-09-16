with dbt_source_freshness_results as (

    select
        source_freshness_execution_id,
        unique_id,
        status,
        max_loaded_at,
        max_loaded_at_time_ago_in_s,
        snapshotted_at,
        error,
        created_at

    from {{ ref('elementary', 'dbt_source_freshness_results') }}

),

dbt_sources as (

    select
        unique_id,
        source_name,
        name,
        schema_name,
        row_number() over (
            partition by unique_id order by generated_at desc
        ) as recency_rank

    from {{ ref('elementary', 'dbt_sources') }}

    qualify recency_rank = 1

),

freshness_with_source as (

    select
        dbt_source_freshness_results.source_freshness_execution_id,
        dbt_source_freshness_results.unique_id,
        dbt_source_freshness_results.status,
        dbt_source_freshness_results.max_loaded_at,
        dbt_source_freshness_results.max_loaded_at_time_ago_in_s,
        dbt_source_freshness_results.snapshotted_at,
        dbt_source_freshness_results.error,
        dbt_source_freshness_results.created_at,
        dbt_sources.source_name,
        dbt_sources.name as table_name,
        dbt_sources.schema_name

    from dbt_source_freshness_results

    inner join dbt_sources
        on dbt_source_freshness_results.unique_id = dbt_sources.unique_id

),

final as (

    select
        source_freshness_execution_id,
        unique_id,
        source_name,
        table_name,
        schema_name,
        status,
        max_loaded_at,
        max_loaded_at_time_ago_in_s,
        snapshotted_at,
        error,
        created_at

    from freshness_with_source

)

select * from final
