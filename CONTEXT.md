# CONTEXT — steam-analytics

A dbt Core project that transforms the `steam-infra` Snowflake landing tables
into an analytics-ready warehouse: conformed dimensions, core facts,
currency-normalized revenue, and per-team spoke marts. Hub-and-spoke: Central
Data Eng owns `staging → intermediate → marts/core`; three spokes
(Product, Marketing, Finance) build only on `marts/core`.

## Glossary

Use these terms verbatim in model names, tests, issue titles, and docs. Where
a synonym is listed as *avoid*, do not drift to it.

### CDC landing

- **landing table** — one Snowflake table per `steam-infra` source table, written
  by the CDC connector (`ExtractNewRecordState` + schematization, see
  [ADR 0001](docs/adr/0001-cdc-landing-shape.md)). Holds one typed column per
  source column, the **CDC bookkeeping columns**, and a `RECORD_METADATA`
  VARIANT. *Avoid* "raw table" / "RECORD_CONTENT" — the envelope is flattened
  before it lands.
- **CDC bookkeeping column** — a `__`-prefixed column added by the connector:
  `__op`, `__source_ts_ms`, `__source_lsn`, `__source_snapshot`,
  `__source_table`, `__source_txid`, `__deleted`. Together with `RECORD_METADATA`,
  these are dropped by the `stg` layer — except `is_deleted`, which a `stg` model
  derives from `__deleted`.
- **source event time** — `__source_ts_ms`, the database commit time of the
  change (epoch ms). The freshness `loaded_at_field`. *Avoid* `RECORD_METADATA`
  `CreateTime` (Kafka produce time, reset on every re-snapshot).
- **offset dedupe** — `steam-infra` runs `snapshot.mode=always` with no persisted
  offsets, so every connector restart re-emits every row as an `op='r'` event.
  Each `stg` model keeps the row with the highest `RECORD_METADATA:offset` per
  primary key (one partition per topic → offset is a total order).

### Layers

- **staging** — one model per landing table (`stg_steam__<entity>`). Casts,
  renames, offset-dedupes, drops CDC bookkeeping columns. No joins, no business
  logic. Materialized as `view`. Schema: `stg`.
- **intermediate** — reusable business logic that is not itself a mart
  (`int_<verb>_<noun>`): sessionization, SCD2 replay prep, event unnesting,
  FX join helpers. Materialized as `view`. Schema: `int`.
- **marts/core** — conformed `dim_*` / `fct_*`. The only layer a spoke may
  `ref()`. Owned by Central Data Eng. Materialized as `table`. Schema:
  `marts_core`.
- **spoke mart** — a `marts/<team>/` folder (product, marketing, finance).
  Flat, no subject subfolders. May `ref()` only `marts/core`. Schemas:
  `marts_product`, `marts_marketing`, `marts_finance`.
- **Pipeline Health** — facts about the pipeline itself (`fct_dbt_test_results`,
  `fct_source_freshness`, `fct_row_counts`, `fct_pipeline_runs`), fed by the
  `elementary` package. Lives in `marts/core`, owned by Central Data Eng — not
  a spoke.

### Keys & naming

- **surrogate key** — `dbt_utils.generate_surrogate_key([...])`, named
  `<entity>_key`. Used for joins between marts models.
- **natural id / FK** — keeps `steam-infra`'s `_id` suffix (`user_id`,
  `game_id`). *Avoid* renaming these to `_key`.
- Booleans: `is_` / `has_` prefix. Timestamps: `_at` suffix. Dates: `_date`
  suffix.
- Model prefixes: `stg_<source>__<entity>`, `int_<verb>_<noun>`, `dim_*`,
  `fct_*`. `mart_*` only for a wide denormalized dashboard-feed table if one
  is genuinely needed.

### Conformed dimensions

- **dim_users** — type 1. One row per user, latest attributes. Carries
  `country` (nullable until infra ticket) and immutable first-touch
  `campaign_id` (nullable; `NULL` = organic/direct, *not* a fake "organic"
  campaign row).
- **dim_games** — type 1. One row per game.
- **dim_game_prices** — genuine **SCD2**. One row per
  `game_id × region × [valid_from, valid_to)`, replayed from the
  `price_changes` event log. `is_current = true` for the open interval.
- **dim_date** — generated date spine over the project's active window.

### Core facts

- **fct_purchases** — one row per purchase. Carries `amount_cents` +
  `currency` and derived `amount_usd`.
- **amount_usd** — `amount_cents / 100 * rate_to_usd`, where `rate_to_usd`
  comes from the **fx_rates** seed joined on `purchased_at::date × currency`.
  Missing FX rate for a (date, currency) is a test failure, not a silent null.
- **fct_refunds** — one row per refund. `is_chargeback` flag, linked to its
  purchase. A **chargeback** is a bank-initiated reversal; tracked as a
  distinct failure mode from an ordinary refund — *avoid* conflating the two.
- **fct_ownership_grants** — one row per grant. `source ∈ {purchase, gift,
  key_redemption}`, with `granted_at` / `revoked_at`.
- **fct_playtime_sessions** — one row per gameplay session. `duration_minutes`
  (null when open), `is_open` flag.
- **fct_concurrent_player_snapshots** — one row per `game × snapshot`.

### Acquisition (Marketing) — distinct concepts, keep separate

- **campaign_id** (on `dim_users`) — *why* a user signed up. Immutable
  first-touch, set once at account creation. `NULL` = organic.
- **source** (on `fct_ownership_grants`) — *how* a user got the game
  (purchase / gift / key_redemption). Orthogonal to `campaign_id`.
- **browsing session** (`client_events.session_id`) — a store-browsing visit.
  Distinct from **playtime session**, which tracks only gameplay.

### fx_rates seed

`seeds/fx_rates.csv` — `date, currency, rate_to_usd`. Synthetic daily rates
covering USD/EUR/GBP/BRL/JPY over the project window. `USD` rows = `1.0`. The
only reference-data seed in the project.

## Decisions

ADRs live in `docs/adr/`:

- [0001 — CDC landing shape](docs/adr/0001-cdc-landing-shape.md): flattened,
  schematized landing tables (`ExtractNewRecordState` + `schemas.enable=true` +
  `snowflake.enable.schematization=true`); `before` image dropped; offset dedupe.

Open decisions tracked in issue #9 under "Open decisions to resolve in-flight".
