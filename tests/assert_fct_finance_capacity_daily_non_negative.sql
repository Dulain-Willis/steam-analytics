-- Singular test (issue #18): peak_concurrent_players on
-- fct_finance_capacity_daily must be non-negative. Fails on any row with a
-- negative peak_concurrent_players.

with capacity_daily as (

    select * from {{ ref('fct_finance_capacity_daily') }}

)

select *
from capacity_daily
where peak_concurrent_players < 0
