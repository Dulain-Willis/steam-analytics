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
--
-- Deliberately does NOT filter out is_deleted rows the way a table-
-- materialized mart does: incremental_strategy='merge' only ever upserts
-- rows present in this model's own select - it can't delete a row that's
-- already landed here and later gets soft-deleted upstream, because that
-- row would simply stop appearing in the filtered select and the merge
-- would never touch its prior copy. is_deleted is carried through
-- instead, and every downstream consumer (fct_product_wishlist_conversion)
-- filters `where not is_deleted` itself.
{{
    config(
        materialized='incremental',
        unique_key='ownership_grant_key',
        incremental_strategy='merge',
    )
}}

with

ownership_grants as (

    select * from {{ ref('stg_steam__ownership_grants') }}

),

{% if is_incremental() %}

    within_lookback_window as (

        select *

        from ownership_grants

        where {{ incremental_lookback_filter() }}

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
        recorded_at,
        is_deleted

    from {{ 'within_lookback_window' if is_incremental() else 'ownership_grants' }}

)

select * from final
