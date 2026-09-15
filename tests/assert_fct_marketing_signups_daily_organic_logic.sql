-- Singular test (issue #22): independently re-derives organic vs.
-- campaign-attributed signup counts straight from dim_users /
-- dim_marketing_campaigns, then fails on any mismatch against what
-- fct_marketing_signups_daily reports per signup_date x channel. Catches a
-- regression that dropped a user, miscounted organic (NULL campaign_id), or
-- mapped a campaign to the wrong channel.

with users as (

    select
        signup_date,
        campaign_id

    from {{ ref('dim_users') }}

),

marketing_campaigns as (

    select
        marketing_campaign_id,
        channel

    from {{ ref('dim_marketing_campaigns') }}

),

expected as (

    select
        users.signup_date,
        coalesce(marketing_campaigns.channel, 'organic') as channel,
        count(*) as expected_signup_count

    from users
    left join marketing_campaigns
        on users.campaign_id = marketing_campaigns.marketing_campaign_id

    group by 1, 2

),

actual as (

    select
        signup_date,
        channel,
        signup_count as actual_signup_count

    from {{ ref('fct_marketing_signups_daily') }}

),

compared as (

    select
        coalesce(expected.signup_date, actual.signup_date) as signup_date,
        coalesce(expected.channel, actual.channel) as channel,
        coalesce(expected.expected_signup_count, 0)
            as expected_signup_count,
        coalesce(actual.actual_signup_count, 0) as actual_signup_count

    from expected
    full outer join actual
        on
            expected.signup_date = actual.signup_date
            and expected.channel = actual.channel

)

select *
from compared
where expected_signup_count <> actual_signup_count
