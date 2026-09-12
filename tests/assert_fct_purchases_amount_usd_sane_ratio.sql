-- Singular test (issue #17): amount_usd should sit within a sane ratio band
-- of amount_cents - i.e. the effective rate_to_usd implied by
-- amount_usd / (amount_cents / 100) should be a plausible currency rate.
-- Catches gross FX-join errors (wrong join grain, missing /100, fanned-out
-- duplicate rate rows) rather than validating exact rates.

with purchases as (

    select * from {{ ref('fct_purchases') }}
    where amount_usd is not null and amount_cents <> 0

),

with_implied_rate as (

    select
        *,
        amount_usd / (amount_cents / 100.0) as implied_rate_to_usd

    from purchases

)

select *
from with_implied_rate
where implied_rate_to_usd not between 0.0001 and 10
