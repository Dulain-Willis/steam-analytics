-- stg_steam__concurrent_player_snapshots: cast/rename/offset-dedupe over the
-- steam.concurrent_player_snapshots landing table. No joins, no business
-- logic.

with source as (

    select * from {{ source('steam', 'concurrent_player_snapshots') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as concurrent_player_snapshot_id,
    game_id,
    player_count,
    snapshot_at::timestamp_tz as snapshot_at,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
