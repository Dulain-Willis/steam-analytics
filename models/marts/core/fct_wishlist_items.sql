-- fct_wishlist_items: one row per wishlist add. removed_at stays null while
-- the item is still wishlisted - mirrors fct_playtime_sessions' open-session
-- handling (a still-open state is a null column, not a sentinel value).

with wishlist_items as (

    select * from {{ ref('stg_steam__wishlist_items') }}
    where not is_deleted

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['wishlist_item_id']) }}
            as wishlist_item_key,
        {{ dbt_utils.generate_surrogate_key(['user_id']) }} as user_key,
        {{ dbt_utils.generate_surrogate_key(['game_id']) }} as game_key,
        added_at,
        added_at::date as added_date,
        removed_at

    from wishlist_items

)

select * from final
