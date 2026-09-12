-- stg_steam__marketing_campaigns: cast/rename/offset-dedupe over the
-- steam.marketing_campaigns landing table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'marketing_campaigns') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as marketing_campaign_id,
    name,
    channel,
    spend_cents,
    currency,
    starts_at::timestamp_tz as starts_at,
    ends_at::timestamp_tz as ends_at,
    created_at::timestamp_tz as created_at,
    coalesce(__deleted, false) as is_deleted

from source
