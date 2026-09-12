-- stg_steam__key_redemptions: cast/rename/offset-dedupe over the
-- steam.key_redemptions landing table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'key_redemptions') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as key_redemption_id,
    key_hash,
    user_id,
    game_id,
    redeemed_at::timestamp_tz as redeemed_at,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
