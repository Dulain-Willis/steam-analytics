-- int_users_campaign_attribution: every user's first-touch acquisition
-- channel, resolved from dim_users.campaign_id via dim_marketing_campaigns.
-- A NULL campaign_id resolves to the 'organic' channel here - the only
-- place this coalesce happens; it is never materialized as a fake row in
-- dim_marketing_campaigns (CONTEXT.md). Shared by every marts/marketing
-- fact that needs a user's channel or campaign attribution (issue #22).
--
-- The unknown-member sentinel (steam-infra #141) is excluded here: it
-- isn't a real signup, and its NULL created_at/signup_date would otherwise
-- leak a fake row into every downstream signup count.
with

users as (

    select
        user_key,
        signup_date,
        campaign_id

    from {{ ref('dim_users') }}

    where not is_unknown_member

),

marketing_campaigns as (

    select
        marketing_campaign_key,
        marketing_campaign_id,
        channel

    from {{ ref('dim_marketing_campaigns') }}

),

final as (

    select
        users.user_key,
        users.signup_date,
        users.campaign_id,
        marketing_campaigns.marketing_campaign_key,
        coalesce(marketing_campaigns.channel, 'organic') as channel

    from users

    left join marketing_campaigns
        on users.campaign_id = marketing_campaigns.marketing_campaign_id

)

select * from final
