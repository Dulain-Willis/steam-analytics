-- fct_marketing_signups_daily: one row per signup_date x channel. Channel
-- resolution (NULL campaign_id -> 'organic') lives in
-- int_users_campaign_attribution, shared with the CPA/revenue facts
-- (issue #22).

with users_campaign_attribution as (

    select
        signup_date,
        channel

    from {{ ref('int_users_campaign_attribution') }}

),

final as (

    select
        signup_date,
        channel,

        {{
            dbt_utils.generate_surrogate_key(
                ['signup_date', 'channel']
            )
        }} as marketing_signups_daily_key,

        count(*) as signup_count

    from users_campaign_attribution

    group by 1, 2

)

select * from final
