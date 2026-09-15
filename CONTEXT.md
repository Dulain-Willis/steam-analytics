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
  Flat, no subject subfolders. May `ref()` only `marts/core` - except
  `fct_product_funnel_sessions` (issue #23), sanctioned to `ref()` the
  `client_events` staging model directly, since the funnel is event-grain
  and has no `marts/core` conformed source to build on. Schemas:
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
  `price_changes` event log (replay prep lives in
  `int_game_prices_replayed`). `is_current = true` for the open interval.
  **Initial-price rule** (resolved): a `game_id × region` with
  `price_changes` history gets an initial interval seeded from the
  earliest change's `old_price_cents`, anchored at `dim_games.created_at`
  (or, if that earliest change's `old_price_cents` is itself null — no
  price existed before it — its `new_price_cents` extends back to
  `created_at` instead). A `game_id × region` with no `price_changes`
  history at all falls back to its current `game_prices` row, likewise
  anchored at `created_at`.
- **dim_date** — generated date spine (`dbt_utils.date_spine`) over the
  project's active window, `2023-01-01` to `2027-01-01`
  (`vars.dim_date_start_date` / `dim_date_end_date` in `dbt_project.yml`).
- **dim_marketing_campaigns** — type 1. One row per campaign. Lives in
  `marts/core`, not `marts/marketing`, so `dim_users.campaign_id` and every
  spoke conform on the same `marketing_campaign_key` (spokes may `ref()` only
  `marts/core`). `channel` enum: `paid_search`, `paid_social`, `email`,
  `influencer`, `affiliate`.

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
  Boundary decision (issue #23): the session is whatever `session_id` the
  client emits on each event — an explicit marker, not a gap-inferred
  session computed downstream from `occurred_at`. *Avoid* re-deriving
  session boundaries from an inactivity gap. Distinct from **playtime
  session**, which tracks only gameplay.
- **fct_product_funnel_sessions** — one row per browsing session, over the
  stages `store_page_view -> game_page_view -> add_to_wishlist ->
  begin_checkout -> purchase_complete`. `purchase_complete` is a marker
  event only; dollar / grant detail comes from `fct_ownership_grants`, not
  event props.
- **int_users_campaign_attribution** — one row per user, resolving
  `dim_users.campaign_id` to a `channel` (NULL `campaign_id` -> `'organic'`
  here only - never a fake row in `dim_marketing_campaigns`). Shared by
  every `marts/marketing` fact that needs channel/campaign attribution.
- **marts/marketing** — `fct_marketing_signups_daily` (date x channel),
  `fct_marketing_campaign_cpa` (one row per campaign; `spend_cents` /
  `attributed_signup_count`, no time window - `cpa_usd` is `null` for a
  campaign with zero attributed signups, an undefined ratio, not a
  misleading `0` - roll up to channel by summing both measures and
  recomputing the ratio, not by averaging `cpa_usd`), and
  `fct_marketing_campaign_revenue` (one row per campaign; lifetime
  `fct_purchases.amount_usd` for attributed users only, unbounded window -
  organic revenue is out of scope here).

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
