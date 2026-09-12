-- stg_steam__gifts: cast/rename/offset-dedupe over the steam.gifts landing
-- table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'gifts') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as gift_id,
    purchase_id,
    sender_id,
    recipient_id,
    sent_at::timestamp_tz as sent_at,
    redeemed_at::timestamp_tz as redeemed_at,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
