-- Singular test (issue #17): amount_usd must be populated wherever currency
-- is populated. fct_purchases left-joins fx_rates, so a missing FX rate for
-- a (date, currency) pair shows up here as a null amount_usd instead of
-- passing silently.

with purchases as (

    select * from {{ ref('fct_purchases') }}

)

select *
from purchases
where currency is not null and amount_usd is null
