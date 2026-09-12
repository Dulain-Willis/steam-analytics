-- int_purchases_with_fx: purchases joined to their FX rate, with derived
-- keys and amount_usd already computed. Shared by fct_purchases and
-- fct_refunds so both derive purchase_key / user_key / game_key /
-- amount_usd from one place instead of each recomputing the surrogate keys
-- independently. Left unfiltered by is_deleted - each consumer decides
-- whether a deleted purchase belongs in its own grain.

with purchases as (

    select * from {{ ref('stg_steam__purchases') }}

),

fx_rates as (

    select * from {{ ref('fx_rates') }}

),

purchases_with_fx as (

    select
        purchases.purchase_id,
        purchases.user_id,
        purchases.game_id,
        purchases.amount_cents,
        purchases.currency,
        purchases.payment_method,
        purchases.purchased_at,
        purchases.is_deleted,
        fx_rates.rate_to_usd

    from purchases
    left join fx_rates
        on purchases.purchased_at::date = fx_rates.date
          and purchases.currency = fx_rates.currency

),

final as (

    select
        purchase_id,

        {{
            dbt_utils.generate_surrogate_key(['purchase_id'])
        }} as purchase_key,

        {{ dbt_utils.generate_surrogate_key(['user_id']) }} as user_key,

        {{ dbt_utils.generate_surrogate_key(['game_id']) }} as game_key,
        purchased_at,
        purchased_at::date as purchase_date,
        amount_cents,
        currency,
        amount_cents / 100.0 * rate_to_usd as amount_usd,
        payment_method,
        is_deleted

    from purchases_with_fx

)

select * from final
