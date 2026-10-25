-- fct_playtime_sessions: one row per gameplay session. A session with no
-- ended_at is still in progress: is_open flags it explicitly and
-- duration_minutes stays null rather than being computed against "now"
-- (which would silently change on every run).
--
-- Incremental merge on playtime_session_key (#135, copying #134's
-- pattern). The filter guards on recorded_at (arrival timestamp), not
-- started_at/ended_at (event timestamps): a restated or late-arriving
-- session keeps its original started_at but re-lands with a fresh
-- recorded_at, so filtering on event time would silently drop it from
-- every incremental run after its original one. recorded_at is kept in
-- the output (not just the filter) so that max(recorded_at) is readable
-- straight off this table on the next run.
--
-- Deliberately does NOT filter out is_deleted rows the way the prior
-- table-materialized version did: incremental_strategy='merge' only ever
-- upserts rows present in this model's own select - it can't delete a row
-- that's already landed here and later gets soft-deleted upstream,
-- because that row would simply stop appearing in the filtered select and
-- the merge would never touch its prior copy. is_deleted is carried
-- through instead, and every downstream consumer
-- (fct_product_active_users_daily, fct_product_session_length_daily)
-- filters `where not is_deleted` itself.
--
-- on_schema_change='fail' (#144): a contract-enforced incremental model
-- can't use the default 'ignore' - dbt requires 'append_new_columns' or
-- 'fail' here. 'fail' matches the contract's own intent: the columns:
-- list in _core__models.yml is the single source of truth for this
-- model's shape, so a drift should error loudly, not silently widen it.
{{
    config(
        materialized='incremental',
        unique_key='playtime_session_key',
        incremental_strategy='merge',
        on_schema_change='fail',
    )
}}

with

playtime_sessions as (

    select * from {{ ref('stg_steam__playtime_sessions') }}

),

{% if is_incremental() %}

    within_lookback_window as (

        select *

        from playtime_sessions

        where {{ incremental_lookback_filter() }}

    ),

{% endif %}

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['playtime_session_id']) }} as playtime_session_key,
        {{ dbt_utils.generate_surrogate_key(['user_id']) }} as user_key,
        {{ dbt_utils.generate_surrogate_key(['game_id']) }} as game_key,
        started_at,
        started_at::date as started_date,
        recorded_at,
        (ended_at is null) as is_open,
        -- Pinned to a fixed numeric type on purpose. ended_at is TEXT in the
        -- landing table (the sink types a nullable timestamp whose first
        -- observed value is null as TEXT), so the precision Snowflake infers
        -- for this datediff drifts with the data. On a contract-enforced
        -- incremental model that drift trips on_schema_change='fail':
        -- observed live on the #129 bring-up as
        --   New column types: [{'column_name': 'DURATION_MINUTES',
        --                       'new_type': 'NUMBER(18,0)'}]
        -- after the generator was redeployed, with no model change at all.
        -- Without the cast this model fails intermittently whenever the
        -- inferred precision moves.
        case
            when ended_at is not null
                then datediff('minute', started_at, ended_at)
        end::number(18, 0) as duration_minutes,
        is_deleted

    from {{ 'within_lookback_window' if is_incremental() else 'playtime_sessions' }}

)

select * from final
