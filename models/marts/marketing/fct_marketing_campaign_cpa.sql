-- fct_marketing_campaign_cpa: one row per campaign. attributed_signup_count
-- is every user first-touch attributed to the campaign
-- (int_users_campaign_attribution) - no time window, matching spend_cents,
-- which is steam-infra's lifetime campaign total, not a daily breakdown
-- (issue #22). cpa_usd is null when a campaign has zero attributed
-- signups - an undefined ratio (spend with no signups is a very bad CPA,
-- not a free $0 one), not div0'd to a misleading 0.

with marketing_campaigns as (

    select
        marketing_campaign_key,
        channel,
        spend_cents

    from {{ ref('dim_marketing_campaigns') }}

),

attributed_users as (

    select marketing_campaign_key
    from {{ ref('int_users_campaign_attribution') }}
    where campaign_id is not null

),

attributed_signups as (

    select
        marketing_campaign_key,
        count(*) as attributed_signup_count

    from attributed_users

    group by 1

),

final as (

    select
        {{
            dbt_utils.generate_surrogate_key(
                ['marketing_campaigns.marketing_campaign_key']
            )
        }} as marketing_campaign_cpa_key,
        
        marketing_campaigns.marketing_campaign_key,
        marketing_campaigns.channel,
        marketing_campaigns.spend_cents,

        coalesce(
            attributed_signups.attributed_signup_count, 0
          ) as attributed_signup_count,

        case
            when coalesce(attributed_signups.attributed_signup_count, 0) = 0
                then null
            else
                marketing_campaigns.spend_cents / 100.0
                / attributed_signups.attributed_signup_count
        end as cpa_usd

    from marketing_campaigns
    left join attributed_signups
        on marketing_campaigns.marketing_campaign_key
        = attributed_signups.marketing_campaign_key

)

select * from final
