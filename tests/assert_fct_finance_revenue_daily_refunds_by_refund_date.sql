-- Singular test (issue #18): refunds must deduct in the period they were
-- refunded (fct_refunds.refund_date, from refunded_at), never restating the
-- original purchase period. Independently re-aggregates refunded_cents by
-- refund_date x country x is_chargeback from fct_refunds and fails on any
-- mismatch against what fct_finance_revenue_daily reports for that same
-- grain - catching a regression that grouped refunds by purchase_date (or
-- any other period) instead.

with refunds as (

    select
        refund_date,
        user_key,
        is_chargeback,
        refunded_amount_usd

    from {{ ref('fct_refunds') }}

),

users as (

    select
        user_key,
        country

    from {{ ref('dim_users') }}

),

revenue_daily as (

    select
        revenue_date,
        country,
        is_chargeback,
        refunded_cents

    from {{ ref('fct_finance_revenue_daily') }}

),

refunds_with_country as (

    select
        refunds.refund_date,
        users.country,
        refunds.is_chargeback,
        refunds.refunded_amount_usd

    from refunds
    inner join users
        on refunds.user_key = users.user_key

),

refunds_by_refund_date as (

    select
        refund_date as revenue_date,
        country,
        is_chargeback,
        round(sum(refunded_amount_usd) * 100)::int as refunded_cents

    from refunds_with_country

    group by 1, 2, 3

),

compared as (

    select
        coalesce(
            refunds_by_refund_date.revenue_date, revenue_daily.revenue_date
        ) as revenue_date,
        coalesce(
            refunds_by_refund_date.country, revenue_daily.country
        ) as country,
        coalesce(
            refunds_by_refund_date.is_chargeback, revenue_daily.is_chargeback
        ) as is_chargeback,
        coalesce(refunds_by_refund_date.refunded_cents, 0)
            as expected_refunded_cents,
        coalesce(revenue_daily.refunded_cents, 0)
            as actual_refunded_cents

    from refunds_by_refund_date
    full outer join revenue_daily
        on
            refunds_by_refund_date.revenue_date = revenue_daily.revenue_date
            and refunds_by_refund_date.country
            is not distinct from revenue_daily.country
            and refunds_by_refund_date.is_chargeback
            = revenue_daily.is_chargeback

)

select *
from compared
where expected_refunded_cents <> actual_refunded_cents
