-- fct_product_wishlist_conversion: conversion is decided per wishlist_items
-- row, then rolled up to one row per game (issue #19). A wishlist row
-- counts as converted if any fct_ownership_grants row exists for that same
-- (user, game) with granted_at after the wishlist add - any source
-- (purchase, gift, key_redemption), over an unbounded ever-converted
-- window, not just the next N days. days_to_convert is measured to the
-- earliest such qualifying grant.

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

wishlist_items_with_first_qualifying_grant as (

    select
        wishlist_items.wishlist_item_key,
        wishlist_items.game_key,
        wishlist_items.added_at,
        min(ownership_grants.granted_at) as first_qualifying_grant_at

    from wishlist_items
    left join ownership_grants
        on
            wishlist_items.user_key = ownership_grants.user_key
            and wishlist_items.game_key = ownership_grants.game_key
            and wishlist_items.added_at < ownership_grants.granted_at

    group by 1, 2, 3

),

wishlist_items_scored as (

    select
        game_key,
        (first_qualifying_grant_at is not null) as is_converted,
        datediff(
            'day', added_at, first_qualifying_grant_at
        ) as days_to_convert

    from wishlist_items_with_first_qualifying_grant

),

final as (

    select
        game_key,
        {{
            dbt_utils.generate_surrogate_key(['game_key'])
        }} as wishlist_conversion_key,
        count(*) as wishlist_add_count,
        count_if(is_converted) as converted_count,
        div0(count_if(is_converted), count(*)) as conversion_rate,
        median(
            case when is_converted then days_to_convert end
        ) as median_days_to_convert

    from wishlist_items_scored

    group by 1

)

select * from final
