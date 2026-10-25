-- fct_arrival_lag (Pipeline Health, #137): observed arrival lag per
-- source table, snapshotted per run, against the configured lookback
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
--
-- "Today's" arrivals are scoped off each table's own max(recorded_at)
-- (its high-water mark), never off current_date()/now() - the same
-- reference frame incremental_lookback_filter() itself uses
-- (CONTEXT.md's "restatement" entry: the filter bounds on the target's
-- own high-water mark, not on wall-clock "now"). A build run while the
-- pipeline is stale would otherwise read a comfortable now()-relative
-- margin while the filter, anchored to a stale high-water mark, is
-- silently dropping rows - the exact failure this monitor exists to
-- surface.
{{
    config(
        materialized='incremental',
        unique_key=['source_table', 'snapshot_date'],
        incremental_strategy='merge',
    )
}}

with

ce_raw as (

    select
        occurred_at as event_at,
        recorded_at,
        is_deleted

    from {{ ref('stg_steam__client_events') }}

),

ps_raw as (

    select
        started_at as event_at,
        recorded_at,
        is_deleted

    from {{ ref('stg_steam__playtime_sessions') }}

),

ce_hwm as (

    select max(recorded_at) as high_water_mark

    from ce_raw

),

ps_hwm as (

    select max(recorded_at) as high_water_mark

    from ps_raw

),

client_events as (

    select
        'client_events' as source_table,
        ce_raw.event_at,
        ce_raw.recorded_at

    from ce_raw

    cross join ce_hwm

    where ce_raw.recorded_at >= dateadd('day', -1, ce_hwm.high_water_mark)
        and not ce_raw.is_deleted

),

playtime_sessions as (

    select
        'playtime_sessions' as source_table,
        ps_raw.event_at,
        ps_raw.recorded_at

    from ps_raw

    cross join ps_hwm

    where ps_raw.recorded_at >= dateadd('day', -1, ps_hwm.high_water_mark)
        and not ps_raw.is_deleted

),

arrivals as (

    select * from client_events

    union all

    select * from playtime_sessions

),

lag_in_days as (

    select
        source_table,
        event_at,
        recorded_at,
        datediff('second', event_at, recorded_at) / 86400.0 as lag_days

    from arrivals

),

daily_lag_by_source as (

    select
        source_table,
        max(recorded_at)::date as snapshot_date,
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
