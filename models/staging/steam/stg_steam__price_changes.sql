-- stg_steam__price_changes: cast/rename/offset-dedupe over the
-- steam.price_changes landing table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'price_changes') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as price_change_id,
    game_id,
    region,
    currency,
    old_price_cents,
    new_price_cents,
    changed_at::timestamp_tz as changed_at,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
