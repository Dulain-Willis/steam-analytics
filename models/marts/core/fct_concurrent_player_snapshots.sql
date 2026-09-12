-- fct_concurrent_player_snapshots: one row per game x snapshot, tracking
-- concurrent player counts over time.

with concurrent_player_snapshots as (

    select * from {{ ref('stg_steam__concurrent_player_snapshots') }}
    where not is_deleted

),

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
        snapshot_at::date as snapshot_date

    from concurrent_player_snapshots

)

select * from final
