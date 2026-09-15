-- Singular test (issue #22): attributed_revenue_usd on
-- fct_marketing_campaign_revenue must never be negative.

with campaign_revenue as (

    select * from {{ ref('fct_marketing_campaign_revenue') }}

)

select *
from campaign_revenue
where attributed_revenue_usd < 0
