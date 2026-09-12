-- stg_steam__client_events: cast/rename/offset-dedupe over the
-- steam.client_events landing table. No joins, no business logic. Primary
-- key is event_id (not id) for this table.

with source as (

    select * from {{ source('steam', 'client_events') }}
    qualify row_number() over (
        partition by event_id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    event_id,
    occurred_at::timestamp_tz as occurred_at,
    user_id,
    session_id,
    game_id,
    event_name,
    parse_json(props) as props,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
