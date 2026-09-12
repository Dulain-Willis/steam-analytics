-- Singular test (issue #19): dau and wau on fct_product_active_users_daily
-- must be non-negative, and wau (a trailing 7-day superset of the day
-- itself) can never be smaller than that day's dau.

with active_users_daily as (

    select * from {{ ref('fct_product_active_users_daily') }}

)

select *
from active_users_daily
where dau < 0 or wau < 0 or wau < dau
