-- Singular test (issue #19): independently re-derives conversion per game
-- straight from the core facts - any grant source counts (no source
-- filter), the window is unbounded (no upper bound on the gap), and a grant
-- only counts if it lands after the wishlist add - then fails on any
-- mismatch against what fct_product_wishlist_conversion reports for that
-- game. Catches a regression that narrowed the grant source, added an
-- upper bound to the window, or allowed a grant before the wishlist add to
-- count.

with wishlist_items as (

    select
        wishlist_item_key,
        user_key,
        game_key,
        added_at

    from {{ ref('fct_wishlist_items') }}

),

ownership_grants as (

    select
        user_key,
        game_key,
        granted_at

    from {{ ref('fct_ownership_grants') }}

),

wishlist_items_scored as (

    select
        wishlist_items.game_key,
        (
            select count(*)
            from ownership_grants
            where
                ownership_grants.user_key = wishlist_items.user_key
                and ownership_grants.game_key = wishlist_items.game_key
                and ownership_grants.granted_at > wishlist_items.added_at
        ) > 0 as is_converted

    from wishlist_items

),

expected as (

    select
        game_key,
        count(*) as expected_wishlist_add_count,
        count_if(is_converted) as expected_converted_count

    from wishlist_items_scored

    group by 1

),

actual as (

    select
        game_key,
        wishlist_add_count as actual_wishlist_add_count,
        converted_count as actual_converted_count

    from {{ ref('fct_product_wishlist_conversion') }}

),

compared as (

    select
        coalesce(expected.game_key, actual.game_key) as game_key,
        coalesce(expected.expected_wishlist_add_count, 0)
            as expected_wishlist_add_count,
        coalesce(actual.actual_wishlist_add_count, 0)
            as actual_wishlist_add_count,
        coalesce(expected.expected_converted_count, 0)
            as expected_converted_count,
        coalesce(actual.actual_converted_count, 0)
            as actual_converted_count

    from expected
    full outer join actual
        on expected.game_key = actual.game_key

)

select *
from compared
where
    expected_wishlist_add_count <> actual_wishlist_add_count
    or expected_converted_count <> actual_converted_count
