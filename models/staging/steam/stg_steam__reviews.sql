-- stg_steam__reviews: cast/rename/offset-dedupe over the steam.reviews
-- landing table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'reviews') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as review_id,
    user_id,
    game_id,
    recommended as is_recommended,
    playtime_at_review_minutes,
    submitted_at::timestamp_tz as submitted_at,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
