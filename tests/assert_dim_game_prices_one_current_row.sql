-- Singular test (issue #16): exactly one is_current row per game_id x
-- region. Fails on any game_id x region with zero or more than one.

with prices as (

    select * from {{ ref('dim_game_prices') }}

),

current_counts as (

    select
        game_id,
        region,
        sum(case when is_current then 1 else 0 end) as current_row_count
    from prices
    group by game_id, region  -- noqa: AM06

)

select *
from current_counts
where current_row_count <> 1
