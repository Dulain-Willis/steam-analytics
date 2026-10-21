-- fct_product_funnel_sessions: one row per browsing session (issue #23).
-- Grouping by client_events.session_id, not user x day, is what keeps
-- repeat browse sessions on the same day from collapsing into one row.
-- purchase_complete is tracked here as a marker event only - dollar /
-- grant detail belongs to fct_ownership_grants, not this model's event
-- props.
--
-- Incremental merge on funnel_session_key (#135, copying #134's pattern).
-- The filter guards each underlying client_events row on its own
-- recorded_at (arrival timestamp), not occurred_at (event timestamp),
-- same as every other incremental fact in this project - a restated or
-- late-arriving event keeps its original occurred_at but re-lands with a
-- fresh recorded_at. recorded_at is kept on the output as the max across
-- a session's events, so max(recorded_at) is readable straight off this
-- table on the next run.
--
-- is_deleted is NOT filtered out of client_events before aggregating
-- (unlike the prior table-materialized version): incremental_strategy=
-- 'merge' only ever upserts sessions present in this model's own select
-- for the current window. If a session's only surviving (non-deleted)
-- event fell outside this run's window, filtering deleted events out
-- here would make the session vanish from the select entirely - and the
-- merge can't retroactively delete its already-materialized row. Instead
-- is_deleted on the output is true only when every event contributing to
-- the session in this run is deleted (booland_agg), and every downstream
-- consumer filters `where not is_deleted` itself.
--
-- on_schema_change='fail' (#144): a contract-enforced incremental model
-- can't use the default 'ignore' - dbt requires 'append_new_columns' or
-- 'fail' here. 'fail' matches the contract's own intent: the columns:
-- list in _product__models.yml is the single source of truth for this
-- model's shape, so a drift should error loudly, not silently widen it.
{{
    config(
        materialized='incremental',
        unique_key='funnel_session_key',
        incremental_strategy='merge',
        on_schema_change='fail',
    )
}}

with

client_events as (

    select
        session_id,
        user_id,
        event_name,
        occurred_at,
        recorded_at,
        is_deleted

    from {{ ref('stg_steam__client_events') }}

    where event_name in (
        'store_page_view',
        'game_page_view',
        'add_to_wishlist',
        'begin_checkout',
        'purchase_complete'
    )

),

{% if is_incremental() %}

    within_lookback_window as (

        select *

        from client_events

        where {{ incremental_lookback_filter() }}

    ),

{% endif %}

session_stage_timestamps as (

    select
        session_id,
        user_id,
        max(recorded_at) as recorded_at,
        booland_agg(is_deleted) as is_deleted,
        min(occurred_at) as session_started_at,
        min(

            case
                when event_name = 'store_page_view' then occurred_at
            end

        ) as store_page_view_at,
        min(

            case
                when event_name = 'game_page_view' then occurred_at
            end

        ) as game_page_view_at,
        min(

            case
                when event_name = 'add_to_wishlist' then occurred_at
            end

        ) as add_to_wishlist_at,
        min(

            case
                when event_name = 'begin_checkout' then occurred_at
            end

        ) as begin_checkout_at,
        min(

            case
                when event_name = 'purchase_complete' then occurred_at
            end

        ) as purchase_complete_at

    from {{ 'within_lookback_window' if is_incremental() else 'client_events' }}

    group by 1,
        2

),

final as (

    select
        session_id,
        user_id,
        {{ dbt_utils.generate_surrogate_key(['session_id']) }} as funnel_session_key,
        date(session_started_at) as session_date,
        session_started_at,
        recorded_at,
        is_deleted,
        store_page_view_at,
        game_page_view_at,
        add_to_wishlist_at,
        begin_checkout_at,
        purchase_complete_at,
        store_page_view_at is not null as has_reached_store_page_view,
        game_page_view_at is not null as has_reached_game_page_view,
        add_to_wishlist_at is not null as has_reached_add_to_wishlist,
        begin_checkout_at is not null as has_reached_begin_checkout,
        purchase_complete_at is not null as has_reached_purchase_complete

    from session_stage_timestamps

)

select * from final
