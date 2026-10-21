-- fct_product_funnel_sessions: one row per browsing session (issue #23).
-- Grouping by client_events.session_id, not user x day, is what keeps
-- repeat browse sessions on the same day from collapsing into one row.
-- purchase_complete is tracked here as a marker event only - dollar /
-- grant detail belongs to fct_ownership_grants, not this model's event
-- props.
--
-- Incremental merge on funnel_session_key (#135, copying #134's pattern),
-- with one wrinkle this model's grain forces: every other incremental
-- fact in this project is 1 output row per 1 input row, so filtering the
-- input by recorded_at and passing it straight to the merge is correct -
-- the merge just leaves any row it didn't touch alone. This model
-- aggregates many client_events rows into one row per session_id, and
-- the merge replaces a session's entire row wholesale. Filtering
-- individual events by recorded_at and aggregating only the surviving
-- subset (the naive copy of the other two models' shape) would silently
-- regress an already-recorded stage any time a session's later event
-- arrives after an earlier stage's event has aged out of the lookback
-- window - the recompute would be missing that earlier event entirely,
-- and the merge has no way to know the row it's about to overwrite had
-- more history than what's in front of it this run. So the filter here
-- decides which *sessions* to touch (any session with at least one event
-- recorded within the window), then every touched session is
-- re-aggregated from its *complete* event history, not just the
-- in-window slice - the merge always replaces a touched row with a fully
-- correct one, same as a full rebuild would produce for that session.
--
-- is_deleted is carried through unfiltered at the session grain (true
-- only when every event contributing to the session is deleted,
-- booland_agg) for the same reason #134 established: a merge can't
-- delete a row that drops out of its own select. But individually
-- deleted events must still be excluded from the stage timestamps/
-- has_reached_* booleans themselves (session_started_at is the one
-- exception - it's a marker, not a stage claim, so it still reflects the
-- session's full event history even if every event in it is deleted,
-- keeping it not-null) - otherwise a session with a mix of deleted and
-- live events would count a deleted event as a reached funnel stage.
-- Every downstream consumer filters `where not is_deleted` itself.
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

    touched_sessions as (

        select distinct session_id

        from client_events

        where {{ incremental_lookback_filter() }}

    ),

    client_events_for_touched_sessions as (

        select client_events.*

        from client_events

        inner join touched_sessions
            on client_events.session_id = touched_sessions.session_id

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
                when event_name = 'store_page_view'
                    and not is_deleted
                    then occurred_at
            end

        ) as store_page_view_at,
        min(

            case
                when event_name = 'game_page_view'
                    and not is_deleted
                    then occurred_at
            end

        ) as game_page_view_at,
        min(

            case
                when event_name = 'add_to_wishlist'
                    and not is_deleted
                    then occurred_at
            end

        ) as add_to_wishlist_at,
        min(

            case
                when event_name = 'begin_checkout'
                    and not is_deleted
                    then occurred_at
            end

        ) as begin_checkout_at,
        min(

            case
                when event_name = 'purchase_complete'
                    and not is_deleted
                    then occurred_at
            end

        ) as purchase_complete_at

    from
        {{
        'client_events_for_touched_sessions'
        if is_incremental()
        else 'client_events'
    }}

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
