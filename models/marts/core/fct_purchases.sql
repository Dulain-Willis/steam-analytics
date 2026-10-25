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
--
-- Deliberately does NOT filter out is_deleted rows the way a table-
-- materialized mart does (CONTEXT.md's "offset dedupe"/`is_deleted` note):
-- incremental_strategy='merge' only ever upserts rows present in this
-- model's own select - it can't delete a row that's already landed here
-- and later gets soft-deleted upstream, because that row would simply stop
-- appearing in the filtered select and the merge would never touch its
-- prior copy. is_deleted is carried through instead, and every downstream
-- consumer of this table filters `where not is_deleted` itself (same as
-- fct_finance_revenue_daily and fct_marketing_campaign_revenue now do).
--
-- payment_method_bucket (#139): the generator can start emitting a new
-- payment_method value with no warning (no check constraint on that
-- column, db/schema.sql) once its onset date passes. This case always has
-- an else, so an unrecognized value lands in the explicit 'unknown'
-- bucket rather than falling out of every category / going null -- the
-- accepted_values warn-severity test on payment_method itself (see
-- _core__models.yml) is what reports the drift.
--
-- on_schema_change='fail' (#144): a contract-enforced incremental model
-- can't use the default 'ignore' - dbt requires 'append_new_columns' or
-- 'fail' here. 'fail' matches the contract's own intent: the columns:
-- list in _core__models.yml is the single source of truth for this
-- model's shape, so a drift should error loudly, not silently widen it.
{{
    config(
        materialized='incremental',
        unique_key='purchase_key',
        incremental_strategy='merge',
        on_schema_change='fail',
    )
}}

with

purchases_with_fx as (

    select * from {{ ref('int_purchases_with_fx') }}

),

{% if is_incremental() %}

    within_lookback_window as (

        select *

        from purchases_with_fx

        where {{ incremental_lookback_filter() }}

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
        payment_method,

        -- Known values kept in sync with payment_method's and
        -- payment_method_bucket's accepted_values tests in
        -- _core__models.yml -- all three list the same three values.
        case
            when payment_method in ('credit_card', 'paypal', 'steam_wallet') then payment_method
            else 'unknown'
        end as payment_method_bucket,

        is_deleted

    from {{ 'within_lookback_window' if is_incremental() else 'purchases_with_fx' }}

)

select * from final
