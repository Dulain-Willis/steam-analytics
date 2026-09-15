-- Singular test (issue #22): signup_count on fct_marketing_signups_daily
-- must never be negative.

with signups_daily as (

    select * from {{ ref('fct_marketing_signups_daily') }}

)

select *
from signups_daily
where signup_count < 0
