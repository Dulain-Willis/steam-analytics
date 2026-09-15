-- dim_marketing_campaigns: type-1, one row per marketing campaign. Lives in
-- marts/core (not marts/marketing) so dim_users.campaign_id and every spoke
-- mart conform on the same campaign_key (CONTEXT.md: spokes may ref() only
-- marts/core).

with marketing_campaigns as (

    select * from {{ ref('stg_steam__marketing_campaigns') }}
    where not is_deleted

),

final as (

    select
        {{
            dbt_utils.generate_surrogate_key(
                ['marketing_campaign_id']
            )
        }} as marketing_campaign_key,

        marketing_campaign_id,
        name,
        channel,
        spend_cents,
        currency,
        starts_at,
        ends_at,
        created_at

    from marketing_campaigns

)

select * from final
