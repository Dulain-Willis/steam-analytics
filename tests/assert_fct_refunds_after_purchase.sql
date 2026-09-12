-- Singular test (issue #17): a refund must happen at or after the purchase
-- it refunds. Fails on any refund whose refunded_at precedes the linked
-- purchase's purchased_at.

with refunds as (

    select * from {{ ref('fct_refunds') }}

),

purchases as (

    select * from {{ ref('fct_purchases') }}

),

refunds_joined_to_purchases as (

    select
        refunds.refund_key,
        refunds.refunded_at,
        purchases.purchased_at

    from refunds
    inner join purchases
        on refunds.purchase_key = purchases.purchase_key

)

select *
from refunds_joined_to_purchases
where refunded_at < purchased_at
