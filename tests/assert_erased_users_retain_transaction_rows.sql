-- Singular test (#143): purchases, refunds, and ownership_grants are tier
-- 3 -- retained untouched under statutory retention, never written by
-- steam-infra's scenarios/deletion_execution.py. Detects by primary key,
-- not by joining back to the erased user: a rewrite-mode CDC delete
-- tombstone is PK-only (steam-infra#129 integration review, finding 4) --
-- user_id/purchase_id are null on the tombstone itself, so a join on
-- either column can never match and the test could never fail no matter
-- what erasure did. Since tier 3 is never hard-deleted for ANY user, a
-- delete tombstone appearing in any of these three tables at all -
-- erased user or not - is the regression this test exists to catch.
with

removed_purchases as (

    select purchase_id as id

    from {{ ref('stg_steam__purchases') }}

    where is_deleted

),

removed_ownership_grants as (

    select ownership_grant_id as id

    from {{ ref('stg_steam__ownership_grants') }}

    where is_deleted

),

removed_refunds as (

    select refund_id as id

    from {{ ref('stg_steam__refunds') }}

    where is_deleted

),

removed_transaction_rows as (

    select 'purchases' as table_name, id from removed_purchases

    union all

    select 'ownership_grants' as table_name, id from removed_ownership_grants

    union all

    select 'refunds' as table_name, id from removed_refunds

)

select table_name, id

from removed_transaction_rows
