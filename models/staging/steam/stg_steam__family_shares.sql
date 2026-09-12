-- stg_steam__family_shares: cast/rename/offset-dedupe over the
-- steam.family_shares landing table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'family_shares') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as family_share_id,
    owner_id,
    borrower_id,
    started_at::timestamp_tz as started_at,
    ended_at::timestamp_tz as ended_at,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
