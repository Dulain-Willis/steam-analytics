-- stg_steam__users: cast/rename/offset-dedupe over the steam.users landing
-- table. No joins, no business logic.
with

source as (

    select *

    from {{ source('steam', 'users') }}

    qualify
        row_number() over (
            partition by id
            order by record_metadata:offset::number desc
        )
        = 1

)

select
    id as user_id,
    username,
    email,
    country,
    campaign_id,
    created_at::timestamp_tz as created_at,
    deletion_requested_at::timestamp_tz as deletion_requested_at,
    -- The durable signal that compliance erasure actually executed for
    -- this user (steam-infra#129 integration review, finding 9) - not
    -- null only once, never cleared. Downstream tests key off this
    -- instead of pattern-matching the username tombstone it also sets.
    deletion_executed_at::timestamp_tz as deletion_executed_at,
    coalesce(__deleted, false) as is_deleted

from source
