-- dim_users: type-1, one row per user. Latest attributes only (staging
-- already offset-deduped). Adds derived signup_date / tenure_days. Also
-- carries the unknown-member sentinel row (steam-infra #141) that an
-- orphan client_events.user_id resolves to - distinct from the existing
-- null-campaign_id = organic convention (CONTEXT.md); no fake campaign row
-- is introduced here.
with

users as (

    select
        user_id,
        username,
        country,
        campaign_id,
        created_at

    from {{ ref('stg_steam__users') }}

    where not is_deleted

),

unknown_member as (

    select
        '{{ unknown_member() }}' as user_id,
        'Unknown member' as username,
        null as country,
        null as campaign_id,
        null as created_at

),

unioned as (

    select * from users

    union all

    select * from unknown_member

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
        datediff('day', created_at::date, current_date()) as tenure_days,
        user_id = '{{ unknown_member() }}' as is_unknown_member

    from unioned

)

select * from final
