-- Singular test (issue #16): no two validity intervals overlap within the
-- same game_id x region. Fails if any row's interval starts before the
-- previous row's interval (ordered by valid_from) has closed.

with prices as (

    select * from {{ ref('dim_game_prices') }}

),

ordered as (

    select
        game_id,
        region,
        valid_from,
        valid_to,
        lag(valid_to) over (
            partition by game_id, region order by valid_from
        ) as prev_valid_to

    from prices

)

select *
from ordered
where
    prev_valid_to is not null
    and valid_from < prev_valid_to
