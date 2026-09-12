-- dim_users: type-1, one row per user. Latest attributes only (staging
-- already offset-deduped). Adds derived signup_date / tenure_days.

with users as (

    select * from {{ ref('stg_steam__users') }}
    where not is_deleted

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['user_id']) }} as user_key,
        user_id,
        username,
        country,
        campaign_id,
        created_at,
        created_at::date as signup_date,
        datediff('day', created_at::date, current_date()) as tenure_days

    from users

)

select * from final
