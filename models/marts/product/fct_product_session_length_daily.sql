-- fct_product_session_length_daily: one row per date x game x
-- new-vs-returning user cohort. Owns the segmentation
-- fct_product_active_users_daily deliberately omits (issue #19) - both the
-- per-game split and the per-game cohort split. A user's cohort is decided
-- per session by comparing that session's started_date to the user's
-- first-ever started_date for that same game (new to this title, not new
-- to the platform - DAU/WAU already covers the platform-wide question) -
-- 'new' on that day, 'returning' on every later one. Open sessions (null
-- duration_minutes) are excluded - a session that hasn't ended yet has no
-- length to measure.

with playtime_sessions as (

    select
        user_key,
        game_key,
        started_date,
        duration_minutes,
        is_open

    from {{ ref('fct_playtime_sessions') }}

),

first_active_dates_per_game as (

    select
        user_key,
        game_key,
        min(started_date) as first_active_date

    from playtime_sessions

    group by 1, 2

),

closed_sessions_with_cohort as (

    select
        playtime_sessions.game_key,
        playtime_sessions.started_date,
        playtime_sessions.duration_minutes,
        case
            when
                playtime_sessions.started_date
                = first_active_dates_per_game.first_active_date
                then 'new'
            else 'returning'
        end as user_cohort

    from playtime_sessions
    inner join first_active_dates_per_game
        on
            playtime_sessions.user_key = first_active_dates_per_game.user_key
            and playtime_sessions.game_key
            = first_active_dates_per_game.game_key

    where not playtime_sessions.is_open

),

final as (

    select
        started_date,
        game_key,
        user_cohort,
        {{
            dbt_utils.generate_surrogate_key(
                ['started_date', 'game_key', 'user_cohort']
            )
        }} as session_length_daily_key,
        count(*) as session_count,
        avg(duration_minutes) as avg_duration_minutes,
        median(duration_minutes) as p50_duration_minutes,
        percentile_cont(0.9)
            within group (order by duration_minutes)
            as p90_duration_minutes

    from closed_sessions_with_cohort

    group by 1, 2, 3

)

select * from final
