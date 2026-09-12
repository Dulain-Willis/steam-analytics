-- dim_game_prices: genuine SCD2. One row per game_id x region x
-- [valid_from, valid_to). Replay logic lives in int_game_prices_replayed.

with game_prices_replayed as (

    select * from {{ ref('int_game_prices_replayed') }}

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['game_id', 'region', 'valid_from']) }}
            as game_price_key,
        game_id,
        region,
        currency,
        price_cents,
        valid_from,
        valid_to,
        is_current

    from game_prices_replayed

)

select * from final
