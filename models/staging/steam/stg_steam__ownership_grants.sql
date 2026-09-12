-- stg_steam__ownership_grants: cast/rename/offset-dedupe over the
-- steam.ownership_grants landing table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'ownership_grants') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as ownership_grant_id,
    user_id,
    game_id,
    source,
    source_id,
    granted_at::timestamp_tz as granted_at,
    revoked_at::timestamp_tz as revoked_at,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
