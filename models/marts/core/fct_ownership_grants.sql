-- fct_ownership_grants: one row per grant of a game to a user, regardless of
-- how it was acquired (source: purchase, gift, or key_redemption).

with ownership_grants as (

    select * from {{ ref('stg_steam__ownership_grants') }}
    where not is_deleted

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['ownership_grant_id']) }}
            as ownership_grant_key,
        {{ dbt_utils.generate_surrogate_key(['user_id']) }} as user_key,
        {{ dbt_utils.generate_surrogate_key(['game_id']) }} as game_key,
        source,
        granted_at,
        revoked_at

    from ownership_grants

)

select * from final
