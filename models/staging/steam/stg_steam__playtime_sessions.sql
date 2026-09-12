-- stg_steam__playtime_sessions: cast/rename/offset-dedupe over the
-- steam.playtime_sessions landing table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'playtime_sessions') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as playtime_session_id,
    user_id,
    game_id,
    started_at::timestamp_tz as started_at,
    ended_at::timestamp_tz as ended_at,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
