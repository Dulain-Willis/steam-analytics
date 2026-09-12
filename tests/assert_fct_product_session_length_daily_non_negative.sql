-- Singular test (issue #19): every measure on
-- fct_product_session_length_daily must be non-negative.

with session_length_daily as (

    select * from {{ ref('fct_product_session_length_daily') }}

)

select *
from session_length_daily
where
    session_count < 0
    or avg_duration_minutes < 0
    or p50_duration_minutes < 0
    or p90_duration_minutes < 0
