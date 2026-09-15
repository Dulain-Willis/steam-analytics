-- Singular test (issue #23): funnel stage timestamps must be
-- non-decreasing within a browsing session - a later-funnel stage can't be
-- reached before an earlier one that was also reached in the same
-- session. Unpivots the reached stages (nulls dropped, so a skipped stage
-- doesn't break the comparison) and fails on any stage that precedes the
-- previous reached stage.

with funnel_sessions as (

    select
        funnel_session_key,
        store_page_view_at,
        game_page_view_at,
        add_to_wishlist_at,
        begin_checkout_at,
        purchase_complete_at

    from {{ ref('fct_product_funnel_sessions') }}

),

stages_unpivoted as (

    select
        funnel_session_key,
        1 as stage_order,
        store_page_view_at as stage_at
    from funnel_sessions
    where store_page_view_at is not null

    union all

    select
        funnel_session_key,
        2 as stage_order,
        game_page_view_at as stage_at
    from funnel_sessions
    where game_page_view_at is not null

    union all

    select
        funnel_session_key,
        3 as stage_order,
        add_to_wishlist_at as stage_at
    from funnel_sessions
    where add_to_wishlist_at is not null

    union all

    select
        funnel_session_key,
        4 as stage_order,
        begin_checkout_at as stage_at
    from funnel_sessions
    where begin_checkout_at is not null

    union all

    select
        funnel_session_key,
        5 as stage_order,
        purchase_complete_at as stage_at
    from funnel_sessions
    where purchase_complete_at is not null

),

ordered as (

    select
        funnel_session_key,
        stage_order,
        stage_at,
        lag(stage_at) over (
            partition by funnel_session_key order by stage_order
        ) as prev_stage_at

    from stages_unpivoted

)

select *
from ordered
where
    prev_stage_at is not null
    and stage_at < prev_stage_at
