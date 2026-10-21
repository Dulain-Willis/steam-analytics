-- fct_purchases: one row per purchase. amount_usd derivation (FX join to
-- the fx_rates seed on purchased_at::date x currency, CONTEXT.md) lives in
-- int_purchases_with_fx, shared with fct_refunds.
--
-- Incremental merge on purchase_key (CONTEXT.md "lookback window" glossary
-- entry). The filter guards on recorded_at (arrival timestamp), not
-- purchased_at (event timestamp): a restated or late-arriving row keeps its
-- original purchased_at but re-lands with a fresh recorded_at, so filtering
-- on event time would silently drop it from every incremental run after its
-- original one. recorded_at is kept in the output (not just the filter) so
-- that max(recorded_at) is readable straight off this table on the next run.
{{
    config(
        materialized='incremental',
        unique_key='purchase_key',
        incremental_strategy='merge',
    )
}}

with

purchases_with_fx as (

    select *

    from {{ ref('int_purchases_with_fx') }}

    where not is_deleted

),

{% if is_incremental() %}

    within_lookback_window as (

        select *

        from purchases_with_fx

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
        purchase_key,
        user_key,
        game_key,
        purchased_at,
        purchase_date,
        recorded_at,
        amount_cents,
        currency,
        amount_usd,
        payment_method

    from {{ 'within_lookback_window' if is_incremental() else 'purchases_with_fx' }}

)

select * from final
