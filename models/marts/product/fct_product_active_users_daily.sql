-- fct_product_active_users_daily: one row per date with any playtime
-- activity (dates with zero sessions don't get a zero-filled row - no
-- dim_date spine join, matching fct_finance_capacity_daily's precedent of
-- only emitting dates the underlying fact actually has). dau is the count
-- of distinct users active that day; wau is the trailing 7-calendar-day
-- distinct count (the day itself plus the prior 6), global with no cohort
-- split (issue #19 - that segmentation lives in
-- fct_product_session_length_daily instead).

with playtime_sessions as (

    select distinct
        started_date,
        user_key

    from {{ ref('fct_playtime_sessions') }}

),

active_dates as (

    select distinct started_date as active_date from playtime_sessions

),

dau as (

    select
        started_date as active_date,
        count(distinct user_key) as dau

    from playtime_sessions

    group by 1

),

wau as (

    select
        active_dates.active_date,
        count(distinct playtime_sessions.user_key) as wau

    from active_dates
    inner join playtime_sessions
        on
            active_dates.active_date >= playtime_sessions.started_date
            and active_dates.active_date
            < dateadd('day', 7, playtime_sessions.started_date)

    group by 1

),

final as (

    select
        dau.active_date,
        {{
            dbt_utils.generate_surrogate_key(['dau.active_date'])
        }} as active_users_daily_key,
        dau.dau,
        wau.wau

    from dau
    inner join wau
        on dau.active_date = wau.active_date

)

select * from final
