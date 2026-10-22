-- fct_arrival_lag (Pipeline Health, #137): observed arrival lag per
-- source table, snapshotted daily, against the configured lookback
-- window (var('arrival_lookback_days')) - so the window's safety margin
-- is monitored rather than assumed. Scoped to the two tables
-- steam-infra's late-arrival knobs can touch (CONTEXT.md's "late
-- arrival" glossary entry): client_events.occurred_at and
-- playtime_sessions.started_at, each measured against that same row's
-- recorded_at. Complements #145's volume/freshness anomaly tests, which
-- this fault class defeats by construction (CONTEXT.md's fault-class
-- table): a late-arriving row substitutes for an on-time one rather
-- than adding to table volume, and recorded_at's max stays "now"
-- regardless, so neither volume_anomalies nor freshness_anomalies ever
-- sees it. This model reads the event-time/recorded_at gap directly
-- instead of inferring it from volume or recency.
{{
    config(
        materialized='incremental',
        unique_key=['source_table', 'snapshot_date'],
        incremental_strategy='merge',
    )
}}

with

client_events as (

    select
        'client_events' as source_table,
        occurred_at as event_at,
        recorded_at

    from {{ ref('stg_steam__client_events') }}

    where recorded_at::date = current_date()

),

playtime_sessions as (

    select
        'playtime_sessions' as source_table,
        started_at as event_at,
        recorded_at

    from {{ ref('stg_steam__playtime_sessions') }}

    where recorded_at::date = current_date()

),

arrivals as (

    select * from client_events

    union all

    select * from playtime_sessions

),

lag_in_days as (

    select
        source_table,
        datediff('second', event_at, recorded_at) / 86400.0 as lag_days

    from arrivals

),

daily_lag_by_source as (

    select
        source_table,
        current_date() as snapshot_date,
        count(*) as arrival_count,
        max(lag_days) as max_lag_days,
        percentile_cont(0.95) within group (order by lag_days) as p95_lag_days

    from lag_in_days

    group by 1

),

final as (

    select
        source_table,
        snapshot_date,
        arrival_count,
        max_lag_days,
        p95_lag_days,
        {{ var('arrival_lookback_days') }} as lookback_window_days,
        {{ var('arrival_lookback_days') }} - p95_lag_days as margin_days

    from daily_lag_by_source

)

select * from final
