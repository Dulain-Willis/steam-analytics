-- stg_steam__purchases: cast/rename/dedupe over the steam.purchases landing
-- table. No joins, no business logic.
with

pk_deduped as (

    -- Primary-key offset dedupe (ADR 0001): a CDC topic carries one
    -- message per change over a row's whole life; collapse to the
    -- highest-offset message per id to get current state.
    select *

    from {{ source('steam', 'purchases') }}

    qualify
        row_number() over (
            partition by id
            order by record_metadata:offset::number desc
        )
        = 1

),

business_key_deduped as (

    -- Business-key dedupe (#133): the charge path isn't idempotent, so a
    -- double-submitted purchase lands as two distinct rows with the same
    -- (user_id, game_id, purchased_at) — distinct ids are the only
    -- difference. Collapse to the highest-offset row per business key,
    -- bucketed by recorded_at into a 1-minute tolerance window so two
    -- independent purchases that happen to land in the same CDC batch
    -- aren't merged just because they coincidentally share a
    -- purchased_at second.
    -- ponytail: fixed-minute bucketing can split a true duplicate pair
    -- straddling a bucket boundary; move to a gaps-and-islands window
    -- (group by proximity in recorded_at rather than a fixed bucket) if
    -- that's ever observed in practice.
    select *

    from pk_deduped

    qualify
        row_number() over (
            partition by user_id, game_id, purchased_at, date_trunc('minute', recorded_at)
            order by record_metadata:offset::number desc
        )
        = 1

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
    coalesce(try_to_boolean(__deleted), false) as is_deleted

from business_key_deduped
