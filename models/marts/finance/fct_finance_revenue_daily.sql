-- fct_finance_revenue_daily: one row per date x users.country x
-- is_chargeback. Revenue/purchase measures only ever land on
-- is_chargeback = false rows - a purchase is never itself a chargeback.
-- Refunds deduct in the period they were refunded (refund_date, derived
-- from refunded_at), never restating the original purchase period
-- (issue #18). country is compared with `is not distinct from` because it
-- is null for every row until the users.country infra ticket lands (soft
-- block, CONTEXT.md) - a plain `=` join would drop every null-country row
-- instead of matching it to itself. chargeback_count mirrors refund_count
-- on is_chargeback = true rows (and is 0 elsewhere), so summing it alone
-- gives total chargebacks without filtering on is_chargeback.

with purchases as (

    select
        purchase_date,
        user_key,
        amount_usd

    from {{ ref('fct_purchases') }}

),

refunds as (

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

purchases_with_country as (

    select
        purchases.purchase_date,
        users.country,
        purchases.amount_usd

    from purchases
    inner join users
        on purchases.user_key = users.user_key

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

purchases_daily as (

    select
        purchase_date as revenue_date,
        country,
        false as is_chargeback,
        round(sum(amount_usd) * 100)::int as revenue_cents,
        count(*) as purchase_count

    from purchases_with_country

    group by 1, 2, 3

),

refunds_daily as (

    select
        refund_date as revenue_date,
        country,
        is_chargeback,
        round(sum(refunded_amount_usd) * 100)::int as refunded_cents,
        count(*) as refund_count

    from refunds_with_country

    group by 1, 2, 3

),

revenue_refund_grain as (

    select
        revenue_date,
        country,
        is_chargeback

    from purchases_daily

    union distinct

    select
        revenue_date,
        country,
        is_chargeback

    from refunds_daily

),

final as (

    select
        revenue_refund_grain.revenue_date,
        revenue_refund_grain.country,
        revenue_refund_grain.is_chargeback,
        {{
            dbt_utils.generate_surrogate_key(
                [
                    'revenue_refund_grain.revenue_date',
                    'revenue_refund_grain.country',
                    'revenue_refund_grain.is_chargeback',
                ]
            )
        }} as finance_revenue_daily_key,
        coalesce(purchases_daily.revenue_cents, 0) as revenue_cents,
        coalesce(refunds_daily.refunded_cents, 0) as refunded_cents,
        coalesce(purchases_daily.purchase_count, 0) as purchase_count,
        coalesce(refunds_daily.refund_count, 0) as refund_count,
        case
            when revenue_refund_grain.is_chargeback
                then coalesce(refunds_daily.refund_count, 0)
            else 0
        end as chargeback_count

    from revenue_refund_grain
    left join purchases_daily
        on
            revenue_refund_grain.revenue_date = purchases_daily.revenue_date
            and revenue_refund_grain.country
            is not distinct from purchases_daily.country
            and revenue_refund_grain.is_chargeback
            = purchases_daily.is_chargeback
    left join refunds_daily
        on
            revenue_refund_grain.revenue_date = refunds_daily.revenue_date
            and revenue_refund_grain.country
            is not distinct from refunds_daily.country
            and revenue_refund_grain.is_chargeback
            = refunds_daily.is_chargeback

)

select * from final
