-- dim_games: type-1, one row per game. Passthrough of games attributes.

with games as (

    select * from {{ ref('stg_steam__games') }}
    where not is_deleted

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['game_id']) }} as game_key,
        game_id,
        name,
        developer,
        publisher,
        genres,
        languages,
        tags,
        created_at

    from games

)

select * from final
