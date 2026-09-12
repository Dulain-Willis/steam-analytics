-- stg_steam__game_prices: cast/rename/offset-dedupe over the
-- steam.game_prices landing table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'game_prices') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as game_price_id,
    game_id,
    region,
    currency,
    price_cents,
    updated_at::timestamp_tz as updated_at,
    coalesce(__deleted, false) as is_deleted

from source
