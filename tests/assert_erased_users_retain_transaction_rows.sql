-- Singular test (#143): purchases, refunds, and ownership_grants are tier
-- 3 -- retained untouched under statutory retention, never written by
-- steam-infra's scenarios/deletion_execution.py. If erasure ever
-- regresses into cascading onto these tables, the CDC delete-derived row
-- (is_deleted = true, derived from __deleted) for the erased user's
-- transaction rows would show up here. Passes trivially (no erased users
-- yet) if no drill has run; fails if an erased user's transaction rows
-- were removed.
with

erased_users as (

    select user_id

    from {{ ref('stg_steam__users') }}

    where username like 'deleted-user-%'

),

removed_purchases as (

    select user_id

    from {{ ref('stg_steam__purchases') }}

    where is_deleted

),

removed_ownership_grants as (

    select user_id

    from {{ ref('stg_steam__ownership_grants') }}

    where is_deleted

),

refunds as (

    select purchase_id

    from {{ ref('stg_steam__refunds') }}

    where is_deleted

),

purchases as (

    select
        purchase_id,
        user_id

    from {{ ref('stg_steam__purchases') }}

),

removed_refunds as (

    select purchases.user_id

    from refunds

    inner join purchases
        on refunds.purchase_id = purchases.purchase_id

),

removed_transaction_rows as (

    select user_id

    from removed_purchases

    union all

    select user_id

    from removed_ownership_grants

    union all

    select user_id

    from removed_refunds

)

select
    erased_users.user_id,
    count(*) as removed_transaction_rows

from erased_users

inner join removed_transaction_rows
    on erased_users.user_id = removed_transaction_rows.user_id

group by 1
