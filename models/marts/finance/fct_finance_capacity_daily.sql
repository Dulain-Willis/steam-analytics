-- fct_finance_capacity_daily: one row per date. peak_concurrent_players is
-- the daily max of platform-wide concurrent players - sum player_count
-- across all games per snapshot_at, then take the max of that per-snapshot
-- total within each snapshot_date (issue #18).

with concurrent_player_snapshots as (

    select
        snapshot_at,
        snapshot_date,
        player_count

    from {{ ref('fct_concurrent_player_snapshots') }}

),

platform_totals_per_snapshot as (

    select
        snapshot_at,
        snapshot_date,
        sum(player_count) as total_concurrent_players

    from concurrent_player_snapshots

    group by 1, 2

),

daily_peak as (

    select
        snapshot_date as capacity_date,
        max(total_concurrent_players) as peak_concurrent_players

    from platform_totals_per_snapshot

    group by 1

),

final as (

    select
        capacity_date,
        {{
            dbt_utils.generate_surrogate_key(['capacity_date'])
        }} as finance_capacity_daily_key,
        peak_concurrent_players

    from daily_peak

)

select * from final
