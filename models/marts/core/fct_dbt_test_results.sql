with dbt_run_results as (

    select
        unique_id,
        status,
        created_at

    from {{ ref('elementary', 'dbt_run_results') }}

    where resource_type = 'test'

),

dbt_tests as (

    select
        unique_id,
        parent_model_unique_id

    from {{ ref('elementary', 'dbt_tests') }}

),

dbt_models as (

    select
        unique_id,
        schema_name

    from {{ ref('elementary', 'dbt_models') }}

),

tests_with_schema as (

    select
        dbt_run_results.status,
        dbt_run_results.created_at,
        dbt_models.schema_name

    from dbt_run_results

    inner join dbt_tests
        on dbt_run_results.unique_id = dbt_tests.unique_id

    inner join dbt_models
        on dbt_tests.parent_model_unique_id = dbt_models.unique_id

),

daily_schema_results as (

    select
        tests_with_schema.created_at::date as run_date,
        tests_with_schema.schema_name,
        count(*) as test_count,
        count_if(tests_with_schema.status = 'pass') as pass_count

    from tests_with_schema

    group by 1, 2

),

final as (

    select
        run_date,
        schema_name,
        test_count,
        pass_count,
        pass_count / nullif(test_count, 0) as pass_rate

    from daily_schema_results

)

select * from final
