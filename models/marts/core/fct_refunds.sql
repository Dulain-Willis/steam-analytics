-- fct_refunds: one row per refund, valued from its linked purchase via
-- int_purchases_with_fx (not fct_purchases, so this doesn't chain fact-to-
-- fact). refunded_amount_usd carries the purchase's amount_usd rather than
-- recomputing an FX conversion - a refund reverses the original charge, so
-- it inherits that charge's value. Filters is_deleted the same way
-- fct_purchases does, so the two stay in lockstep on which purchases exist.

with refunds as (

    select * from {{ ref('stg_steam__refunds') }}
    where not is_deleted

),

purchases_with_fx as (

    select * from {{ ref('int_purchases_with_fx') }}
    where not is_deleted

),

refunds_joined_to_purchases as (

    select
        refunds.refund_id,
        refunds.is_chargeback,
        refunds.refunded_at,
        purchases_with_fx.purchase_key,
        purchases_with_fx.user_key,
        purchases_with_fx.game_key,
        purchases_with_fx.amount_usd as refunded_amount_usd

    from refunds
    inner join purchases_with_fx
        on refunds.purchase_id = purchases_with_fx.purchase_id

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['refund_id']) }} as refund_key,
        purchase_key,
        user_key,
        game_key,
        refunded_at,
        refunded_at::date as refund_date,
        is_chargeback,
        refunded_amount_usd

    from refunds_joined_to_purchases

)

select * from final
