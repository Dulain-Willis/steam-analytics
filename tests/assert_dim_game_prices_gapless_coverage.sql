-- Singular test (issue #16): gap-free coverage from the first interval to
-- is_current within each game_id x region. Fails if any row's valid_from
-- does not exactly match the previous row's valid_to (ordered by
-- valid_from), i.e. there's a gap between consecutive intervals.

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
    and valid_from <> prev_valid_to
