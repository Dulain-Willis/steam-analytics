-- fct_concurrent_player_snapshots: one row per game x snapshot, tracking
-- concurrent player counts over time.
--
-- Incremental merge on concurrent_player_snapshot_key (#135, copying
-- #134's pattern). The filter guards on recorded_at (arrival timestamp),
-- not snapshot_at (event timestamp): a restated or late-arriving snapshot
-- keeps its original snapshot_at but re-lands with a fresh recorded_at, so
-- filtering on event time would silently drop it from every incremental
-- run after its original one. recorded_at is kept in the output (not just
-- the filter) so that max(recorded_at) is readable straight off this
-- table on the next run.
--
-- Deliberately does NOT filter out is_deleted rows the way the prior
-- table-materialized version did: incremental_strategy='merge' only ever
-- upserts rows present in this model's own select - it can't delete a row
-- that's already landed here and later gets soft-deleted upstream,
-- because that row would simply stop appearing in the filtered select and
-- the merge would never touch its prior copy. is_deleted is carried
-- through instead, and every downstream consumer
-- (fct_finance_capacity_daily) filters `where not is_deleted` itself.
--
-- on_schema_change='fail' (#144): a contract-enforced incremental model
-- can't use the default 'ignore' - dbt requires 'append_new_columns' or
-- 'fail' here. 'fail' matches the contract's own intent: the columns:
-- list in _core__models.yml is the single source of truth for this
-- model's shape, so a drift should error loudly, not silently widen it.
{{
    config(
        materialized='incremental',
        unique_key='concurrent_player_snapshot_key',
        incremental_strategy='merge',
        on_schema_change='fail',
    )
}}

with

concurrent_player_snapshots as (

    select * from {{ ref('stg_steam__concurrent_player_snapshots') }}

),

{% if is_incremental() %}

    within_lookback_window as (

        select *

        from concurrent_player_snapshots

        where {{ incremental_lookback_filter() }}

    ),

{% endif %}

final as (

    select
        {{
            dbt_utils.generate_surrogate_key(
                ['concurrent_player_snapshot_id']
            )
        }} as concurrent_player_snapshot_key,
        {{ dbt_utils.generate_surrogate_key(['game_id']) }} as game_key,
        player_count,
        snapshot_at,
        snapshot_at::date as snapshot_date,
        recorded_at,
        is_deleted

    from {{ 'within_lookback_window' if is_incremental() else 'concurrent_player_snapshots' }}

)

select * from final
