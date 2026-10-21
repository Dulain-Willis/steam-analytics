-- fct_ownership_grants: one row per grant of a game to a user, regardless of
-- how it was acquired (source: purchase, gift, or key_redemption).
--
-- Incremental merge on ownership_grant_key (CONTEXT.md "lookback window"
-- glossary entry). The filter guards on recorded_at (arrival timestamp),
-- not granted_at/revoked_at (event timestamps): a restated or late-arriving
-- grant keeps its original granted_at but re-lands with a fresh
-- recorded_at, so filtering on event time would silently drop it from every
-- incremental run after its original one. recorded_at is kept in the
-- output (not just the filter) so that max(recorded_at) is readable
-- straight off this table on the next run.
{{
    config(
        materialized='incremental',
        unique_key='ownership_grant_key',
        incremental_strategy='merge',
    )
}}

with

ownership_grants as (

    select *

    from {{ ref('stg_steam__ownership_grants') }}

    where not is_deleted

),

{% if is_incremental() %}

    within_lookback_window as (

        select *

        from ownership_grants

        where recorded_at >= (
            -- single-table scalar subquery; sqlfluff's qualification rule
            -- misreads the templated outer WHERE as a second table in scope.
            select
                dateadd(
                    'day', -{{ var('arrival_lookback_days') }}, max(recorded_at)  -- noqa: RF02
                )

            from {{ this }}

        )

    ),

{% endif %}

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['ownership_grant_id']) }} as ownership_grant_key,
        {{ dbt_utils.generate_surrogate_key(['user_id']) }} as user_key,
        {{ dbt_utils.generate_surrogate_key(['game_id']) }} as game_key,
        source,
        granted_at,
        revoked_at,
        recorded_at

    from {{ 'within_lookback_window' if is_incremental() else 'ownership_grants' }}

)

select * from final
