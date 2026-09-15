-- fct_marketing_campaign_revenue: one row per campaign.
-- attributed_revenue_usd is the lifetime sum of fct_purchases.amount_usd
-- for users first-touch attributed to this campaign
-- (int_users_campaign_attribution) - unbounded window, regardless of which
-- game or how many purchases (issue #22). Purchases are pre-aggregated to
-- one row per user before joining to users, per the style guide's
-- aggregate-early rule. Organic (NULL campaign_id) revenue is out of scope
-- here - only "attributed users" per the spec, unlike
-- fct_marketing_signups_daily, which does bucket organic.

with marketing_campaigns as (

    select
        marketing_campaign_key,
        channel

    from {{ ref('dim_marketing_campaigns') }}

),

attributed_users as (

    select
        user_key,
        marketing_campaign_key

    from {{ ref('int_users_campaign_attribution') }}
    where campaign_id is not null

),

purchases as (

    select
        user_key,
        amount_usd

    from {{ ref('fct_purchases') }}

),

revenue_by_user as (

    select
        user_key,
        sum(amount_usd) as revenue_usd

    from purchases

    group by 1

),

attributed_revenue as (

    select
        attributed_users.marketing_campaign_key,
        sum(revenue_by_user.revenue_usd) as attributed_revenue_usd

    from attributed_users
    inner join revenue_by_user
        on attributed_users.user_key = revenue_by_user.user_key

    group by 1

),

final as (

    select
        {{
            dbt_utils.generate_surrogate_key(
                ['marketing_campaigns.marketing_campaign_key']
            )
        }} as marketing_campaign_revenue_key,
        marketing_campaigns.marketing_campaign_key,
        marketing_campaigns.channel,
        coalesce(attributed_revenue.attributed_revenue_usd, 0)
            as attributed_revenue_usd

    from marketing_campaigns
    left join attributed_revenue
        on marketing_campaigns.marketing_campaign_key
        = attributed_revenue.marketing_campaign_key

)

select * from final
