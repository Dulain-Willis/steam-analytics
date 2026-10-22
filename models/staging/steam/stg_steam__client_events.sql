-- stg_steam__client_events: cast/rename/offset-dedupe over the
-- steam.client_events landing table. No joins, no business logic. Primary
-- key is event_id (not id) for this table.
--
-- Backfill before the dedupe (steam-infra#129 integration review, finding
-- 6): a rewrite-mode CDC delete tombstone for this table is PK-only
-- (event_id plus __deleted=true) -- every other column, session_id
-- included, is null. client_events rows are insert-once/delete-only (no
-- in-place update path in the generator), so across every CDC row sharing
-- an event_id there is at most one non-null value per column -- backfilling
-- every row, the tombstone included, from that single value is
-- unambiguous. Without this, a hard-deleted event loses session_id and can
-- never be attributed back to the funnel session it belonged to, so
-- fct_product_funnel_sessions.touched_sessions has no way to revisit a
-- session every one of whose events was just deleted.
with

source as (

    select *

    from {{ source('steam', 'client_events') }}

),

backfilled as (

    select
        event_id,
        max(occurred_at) over (partition by event_id) as occurred_at,
        max(user_id) over (partition by event_id) as user_id,
        max(session_id) over (partition by event_id) as session_id,
        max(game_id) over (partition by event_id) as game_id,
        max(event_name) over (partition by event_id) as event_name,
        max(props) over (partition by event_id) as props,
        max(recorded_at) over (partition by event_id) as recorded_at,
        coalesce(__deleted, false) as is_deleted,
        record_metadata

    from source

    qualify
        row_number() over (
            partition by event_id
            order by record_metadata:offset::number desc
        )
        = 1

)

select
    event_id,
    occurred_at::timestamp_tz as occurred_at,
    user_id,
    session_id,
    game_id,
    event_name,
    parse_json(props) as props,
    recorded_at::timestamp_tz as recorded_at,
    is_deleted

from backfilled
