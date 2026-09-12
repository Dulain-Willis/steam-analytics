-- fct_playtime_sessions: one row per gameplay session. A session with no
-- ended_at is still in progress: is_open flags it explicitly and
-- duration_minutes stays null rather than being computed against "now"
-- (which would silently change on every run).

with playtime_sessions as (

    select * from {{ ref('stg_steam__playtime_sessions') }}
    where not is_deleted

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['playtime_session_id']) }}
            as playtime_session_key,
        {{ dbt_utils.generate_surrogate_key(['user_id']) }} as user_key,
        {{ dbt_utils.generate_surrogate_key(['game_id']) }} as game_key,
        started_at,
        started_at::date as started_date,
        (ended_at is null) as is_open,
        case
            when ended_at is not null
                then datediff('minute', started_at, ended_at)
        end as duration_minutes

    from playtime_sessions

)

select * from final
