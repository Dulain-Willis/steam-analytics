-- stg_steam__purchases: cast/rename/offset-dedupe over the steam.purchases
-- landing table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'purchases') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as purchase_id,
    user_id,
    game_id,
    amount_cents,
    currency,
    payment_method,
    purchased_at::timestamp_tz as purchased_at,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
