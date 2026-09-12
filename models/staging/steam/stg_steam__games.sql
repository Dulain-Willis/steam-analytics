-- stg_steam__games: cast/rename/offset-dedupe over the steam.games landing
-- table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'games') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as game_id,
    name,
    developer,
    publisher,
    genres,
    languages,
    parse_json(tags) as tags,
    created_at::timestamp_tz as created_at,
    coalesce(__deleted, false) as is_deleted

from source
