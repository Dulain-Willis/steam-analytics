-- fct_purchases: one row per purchase. amount_usd derivation (FX join to
-- the fx_rates seed on purchased_at::date x currency, CONTEXT.md) lives in
-- int_purchases_with_fx, shared with fct_refunds.

with purchases_with_fx as (

    select * from {{ ref('int_purchases_with_fx') }}
    where not is_deleted

),

final as (

    select
        purchase_key,
        user_key,
        game_key,
        purchased_at,
        purchase_date,
        amount_cents,
        currency,
        amount_usd,
        payment_method

    from purchases_with_fx

)

select * from final
