-- fct_product_funnel_sessions: one row per browsing session (issue #23).
-- Grouping by client_events.session_id, not user x day, is what keeps
-- repeat browse sessions on the same day from collapsing into one row.
-- purchase_complete is tracked here as a marker event only - dollar /
-- grant detail belongs to fct_ownership_grants, not this model's event
-- props.

with

client_events as (

    select
        session_id,
        user_id,
        event_name,
        occurred_at

    from {{ ref('stg_steam__client_events') }}

    where
        not is_deleted
        and event_name in (
            'store_page_view',
            'game_page_view',
            'add_to_wishlist',
            'begin_checkout',
            'purchase_complete'
        )

),

session_stage_timestamps as (

    select
        session_id,
        user_id,
        min(occurred_at) as session_started_at,
        min(
            case when event_name = 'store_page_view' then occurred_at end
        ) as store_page_view_at,
        min(
            case when event_name = 'game_page_view' then occurred_at end
        ) as game_page_view_at,
        min(
            case when event_name = 'add_to_wishlist' then occurred_at end
        ) as add_to_wishlist_at,
        min(
            case when event_name = 'begin_checkout' then occurred_at end
        ) as begin_checkout_at,
        min(
            case when event_name = 'purchase_complete' then occurred_at end
        ) as purchase_complete_at

    from client_events

    group by 1, 2

),

final as (

    select
        session_id,
        user_id,
        {{
            dbt_utils.generate_surrogate_key(['session_id'])
        }} as funnel_session_key,
        date(session_started_at) as session_date,
        session_started_at,
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
