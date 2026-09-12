-- stg_steam__refunds: cast/rename/offset-dedupe over the steam.refunds
-- landing table. No joins, no business logic.

with source as (

    select * from {{ source('steam', 'refunds') }}
    qualify row_number() over (
        partition by id
        order by record_metadata:offset::number desc
    ) = 1

)

select
    id as refund_id,
    purchase_id,
    reason,
    is_chargeback,
    refunded_at::timestamp_tz as refunded_at,
    recorded_at::timestamp_tz as recorded_at,
    coalesce(__deleted, false) as is_deleted

from source
