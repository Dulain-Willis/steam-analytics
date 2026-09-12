-- Singular test (issue #18): every measure on fct_finance_revenue_daily
-- must be non-negative. Fails on any row with a negative revenue_cents,
-- refunded_cents, purchase_count, refund_count, or chargeback_count.

with revenue_daily as (

    select * from {{ ref('fct_finance_revenue_daily') }}

)

select *
from revenue_daily
where
    revenue_cents < 0
    or refunded_cents < 0
    or purchase_count < 0
    or refund_count < 0
    or chargeback_count < 0
