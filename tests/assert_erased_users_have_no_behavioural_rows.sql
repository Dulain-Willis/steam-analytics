-- Singular test (#143): once a user is erased (tombstoned by
-- steam-infra's scenarios/deletion_execution.py), their behavioural rows
-- must actually be gone, not just filtered. Checks active (not is_deleted)
-- rows in each hard-delete-tier staging model for any user whose
-- stg_steam__users row has deletion_executed_at set - the durable
-- execution signal (steam-infra#129 integration review, finding 9),
-- rather than pattern-matching the username tombstone deletion_execution.py
-- also writes as a side effect. Passes trivially (no erased users yet) if
-- no drill has run; fails if an erased user's behavioural rows persist.
with

erased_users as (

    select user_id

    from {{ ref('stg_steam__users') }}

    where deletion_executed_at is not null

),

behavioural_rows as (

    select user_id

    from {{ ref('stg_steam__client_events') }}

    where not is_deleted

    union all

    select user_id

    from {{ ref('stg_steam__playtime_sessions') }}

    where not is_deleted

    union all

    select user_id

    from {{ ref('stg_steam__wishlist_items') }}

    where not is_deleted

)

select
    erased_users.user_id,
    count(*) as persisting_behavioural_rows

from erased_users

inner join behavioural_rows
    on erased_users.user_id = behavioural_rows.user_id

group by 1
