-- int_game_prices_replayed: SCD2 replay prep for dim_game_prices. Turns the
-- price_changes event log into one row per game_id x region x
-- [valid_from, valid_to) interval.
--
-- Initial-price rule (CONTEXT.md): a game_id x region with price_changes
-- history gets an initial interval seeded from the earliest change's
-- old_price_cents, anchored at the game's created_at. A game_id x region
-- with no price_changes history at all falls back to its current
-- game_prices row, also anchored at created_at.

with price_changes as (

    select * from {{ ref('stg_steam__price_changes') }}
    where not is_deleted

),

games as (

    select
        game_id,
        created_at as game_created_at
    from {{ ref('stg_steam__games') }}

),

current_game_prices as (

    select * from {{ ref('stg_steam__game_prices') }}
    where not is_deleted

),

earliest_price_change_per_game_region as (

    select
        game_id,
        region,
        currency,
        old_price_cents,
        changed_at
    from price_changes
    qualify row_number() over (
        partition by game_id, region order by changed_at asc
    ) = 1

),

-- Interval before the first logged change, when the change recorded what
-- price preceded it.
initial_interval_from_price_change_history as (

    select
        earliest_price_change_per_game_region.game_id,
        earliest_price_change_per_game_region.region,
        earliest_price_change_per_game_region.currency,
        earliest_price_change_per_game_region.old_price_cents as price_cents,
        games.game_created_at as valid_from,
        earliest_price_change_per_game_region.changed_at as valid_to

    from earliest_price_change_per_game_region
    inner join games
        on earliest_price_change_per_game_region.game_id = games.game_id
    where earliest_price_change_per_game_region.old_price_cents is not null

),

-- Each change opens an interval; the next change (if any) closes it.
price_change_intervals as (

    select
        price_changes.game_id,
        price_changes.region,
        price_changes.currency,
        price_changes.new_price_cents as price_cents,
        -- when the earliest change has no old_price_cents, it *is* the
        -- initial price: extend it back to the game's creation.
        case
            when
                price_changes.changed_at = earliest_price_change_per_game_region.changed_at
                and earliest_price_change_per_game_region.old_price_cents is null
                then games.game_created_at
            else price_changes.changed_at
        end as valid_from,
        lead(price_changes.changed_at) over (
            partition by price_changes.game_id, price_changes.region
            order by price_changes.changed_at
        ) as valid_to

    from price_changes
    inner join earliest_price_change_per_game_region
        on
            price_changes.game_id = earliest_price_change_per_game_region.game_id
            and price_changes.region = earliest_price_change_per_game_region.region
    inner join games
        on price_changes.game_id = games.game_id

),

-- game_id x region combos with no price_changes history at all.
game_regions_without_price_change_history as (

    select
        current_game_prices.game_id,
        current_game_prices.region,
        current_game_prices.currency,
        current_game_prices.price_cents,
        games.game_created_at as valid_from,
        cast(null as timestamp_tz) as valid_to

    from current_game_prices
    inner join games
        on current_game_prices.game_id = games.game_id
    left join price_changes
        on
            current_game_prices.game_id = price_changes.game_id
            and current_game_prices.region = price_changes.region
    where price_changes.game_id is null

),

all_price_intervals_unioned as (

    select * from initial_interval_from_price_change_history
    union all
    select * from price_change_intervals
    union all
    select * from game_regions_without_price_change_history

),

final as (

    select
        game_id,
        region,
        currency,
        price_cents,
        valid_from,
        valid_to,
        (valid_to is null) as is_current

    from all_price_intervals_unioned

)

select * from final
