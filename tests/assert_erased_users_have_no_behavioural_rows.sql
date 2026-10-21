-- Singular test (#143): once a user is erased (tombstoned by
-- steam-infra's scenarios/deletion_execution.py -- username rewritten to
-- 'deleted-user-<id>'), their behavioural rows must actually be gone, not
-- just filtered. Checks active (not is_deleted) rows in each hard-delete-
-- tier staging model for any user whose stg_steam__users row carries the
-- erasure tombstone. Passes trivially (no erased users yet) if no drill
-- has run; fails if an erased user's behavioural rows persist.
with

erased_users as (

    select user_id

    from {{ ref('stg_steam__users') }}

    where username like 'deleted-user-%'

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
