-- stg_steam__wishlist_items: cast/rename/offset-dedupe over the
-- steam.wishlist_items landing table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'wishlist_items') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as wishlist_item_id,
    user_id,
    game_id,
    added_at::timestamp_tz as added_at,
    removed_at::timestamp_tz as removed_at,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
