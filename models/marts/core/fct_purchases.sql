-- fct_purchases: one row per purchase. amount_usd derivation (FX join to
-- the fx_rates seed on purchased_at::date x currency, CONTEXT.md) lives in
-- int_purchases_with_fx, shared with fct_refunds.
--
-- payment_method_bucket (#139): the generator can start emitting a new
-- payment_method value with no warning (no check constraint on that
-- column, db/schema.sql) once its onset date passes. This case always has
-- an else, so an unrecognized value lands in the explicit 'unknown'
-- bucket rather than falling out of every category / going null -- the
-- accepted_values warn-severity test on payment_method itself (see
-- _core__models.yml) is what reports the drift.
with

purchases_with_fx as (

    select *

    from {{ ref('int_purchases_with_fx') }}

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
        payment_method,

        case
            when payment_method in ('credit_card', 'paypal', 'steam_wallet') then payment_method
            else 'unknown'
        end as payment_method_bucket

    from purchases_with_fx

)

select * from final
