-- Singular test (issue #22): spend_cents, attributed_signup_count, and
-- cpa_usd on fct_marketing_campaign_cpa must never be negative.

with campaign_cpa as (

    select * from {{ ref('fct_marketing_campaign_cpa') }}

)

select *
from campaign_cpa
where
    spend_cents < 0
    or attributed_signup_count < 0
    or cpa_usd < 0
