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
  before it lands. Landing tables live in the **raw database** (`STEAM_RAW`);
  "raw" names the database, never the table shape.
- **CDC bookkeeping column** — a `__`-prefixed column added by the connector:
  `__op`, `__source_ts_ms`, `__source_lsn`, `__source_snapshot`,
  `__source_table`, `__source_txid`, `__deleted`. Together with `RECORD_METADATA`,
  these are dropped by the `stg` layer — except `is_deleted`, which a `stg` model
  derives from `__deleted`.
- **source event time** — `__source_ts_ms`, the database commit time of the
  change (epoch ms). The freshness `loaded_at_field`. *Avoid* `RECORD_METADATA`
  `CreateTime` (Kafka produce time, reset on every re-snapshot).
- **offset dedupe** — `steam-infra` runs `snapshot.mode=initial`
  (`steam-infra`'s `docs/debezium-postgres-config.md`), not `always`: a
  connector restart within a live session resumes from its stored Kafka
  Connect offset instead of re-snapshotting. The real reason `stg` dedupes
  isn't restarts — a CDC topic carries one message per change over a row's
  whole life (every insert/update/delete), and the landing table is
  append-only, so collapsing each primary key down to its highest
  `RECORD_METADATA:offset` (one partition per topic → offset is a total
  order) is how `stg` gets current state at all, with or without a restart.
  `initial` mode does still take a full re-snapshot at the *start* of every
  session (Kafka itself, including its offset topic, is torn down between
  sessions — nothing to resume from), so the dedupe also absorbs that
  session-boundary re-snapshot; within a session it's cheap insurance against
  a forced re-snapshot (e.g. connector CR delete/recreate) rather than a
  load-bearing need. Confirmed against the live connector in `steam-infra`
  #132.
- **business-key dedupe** — a second `stg`-layer dedupe, distinct from offset
  dedupe above and added for the same reason it's needed: the OLTP charge
  path is not idempotent, so a double-submitted purchase lands as two rows
  with *different* primary keys but the same business key (`steam-infra`
  #133's `DUPLICATE_RATE_PURCHASES`). Offset dedupe can't catch this — it
  collapses by primary key, and these rows have distinct ones. `stg` instead
  collapses to the highest-offset row per business key
  (`user_id, game_id, purchased_at`), bucketed into a **tolerance window**
  (`date_trunc('minute', recorded_at)`) so two independent purchases that
  land in the same CDC batch aren't merged just because they happen to share
  a `purchased_at` second. First landed on `stg_steam__purchases`
  (`models/staging/steam/stg_steam__purchases.sql`); a later ticket adding a
  duplicate rate to another transaction table follows the same shape.

### Layers

- **stg layer** — one model per landing table (`stg_steam__<entity>`). Casts,
  renames, offset-dedupes, drops CDC bookkeeping columns. No joins, no business
  logic. Materialized as `view`. Schema: `stg`. *Avoid* calling this layer
  "staging" — **staging** is the environment (see Environments below).
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
  `fct_source_freshness`, `fct_row_counts`), fed by the `elementary` package.
  Lives in `marts/core`, owned by Central Data Eng — not a spoke.
  `fct_pipeline_runs` was named here but was never built; removed (steam-infra
  #145). Elementary's volume/freshness anomaly-detection tests (#145) need no
  fourth model of their own — they run as ordinary dbt generic tests, so
  their results land in `dbt_run_results`/`dbt_tests` exactly like any other
  test and are already picked up by `fct_dbt_test_results`'s existing
  pass/fail aggregation.
- **Anomaly detection vs. source freshness** — `fct_source_freshness` is dbt's
  native source-freshness check: a fixed `warn_after`/`error_after` threshold
  against event-time lag (`__source_ts_ms`) on the raw landing tables only.
  Elementary's `freshness_anomalies`/`volume_anomalies` tests (#145) are a
  different mechanism at a different layer: a statistical comparison against
  each model's own history (row count or newest-row recency), applied to
  `stg` models using arrival time (`recorded_at`) and to `marts/core` facts
  using their event-time column — neither of which dbt's source freshness
  check can reach, since it only runs against declared `source()`s. The two
  are complementary: one catches "this source is older than its contract
  allows," the other catches "this model's volume or recency looks unlike
  itself," even while still inside the contract.

### Which of the seven fault classes anomaly detection actually catches

steam-infra #129's problem statement names seven fault classes. This ticket
(#145) wires `elementary.volume_anomalies`/`freshness_anomalies` across the
`stg` layer and the `marts/core` facts (see `_steam__models.yml`,
`_core__models.yml`). The honest mapping, worked through mechanism by
mechanism rather than assumed:

| Fault class | Mechanism | Caught by #145's anomaly tests? | Actual detector |
|---|---|---|---|
| Backdated updates (continuous) | restates an old row, written now | **Yes** — `volume_anomalies`: the restatement is an extra CDC row landing "now," so it bumps the `recorded_at` bucket's row count even though the row's own event-time is old. | `volume_anomalies` is the sole automated detector; spec says no new handling mechanism is needed beyond `merge` + lookback. |
| Business-key duplicates (continuous, purchases) | second row, same business key, distinct PK | **Yes** — `volume_anomalies` on both `stg_steam__purchases` (`recorded_at`) and `fct_purchases` (`purchased_at`); the duplicate lands in the same bucket as its twin either way. | `volume_anomalies` is a real backstop here — it would have caught this even if the purpose-written `dbt_utils.unique_combination_of_columns` test (#133) had never been written. |
| Late arrival (continuous, client_events/playtime_sessions) | row written now, event-time backdated up to 7d | **No.** It substitutes for an on-time row rather than adding one, so table-wide row count is unaffected, and `recorded_at`'s max is always "now" regardless. Freshness-by-event-time is also unaffected, since on-time rows keep the max fresh. | #137's purpose-built arrival-lag monitor (compares `occurred_at`/`started_at` against `recorded_at` against the configured lookback window) — a bespoke Pipeline Health model, not a generic anomaly test. |
| Unknown enum value onset (payment_method) | new value in an existing column | **No.** Same row count, same timing — only a value changes. Neither row-count nor recency anomaly detection can see a value distribution shift. | Purpose-written warn-severity `accepted_values` test (#139). No anomaly-detection fallback exists for this class. |
| Orphan references (client_events.user_id, FK dropped) | child rows with no matching parent | **No**, as configured — table-wide event volume is unaffected by orphan rate (the same number of child rows arrive either way). Spec names a narrower variant ("anomaly detection on orphan volume") scoped to the unknown-member join via `where_expression`, but that needs the unknown-member row #140/#141 add, which doesn't exist yet. | Purpose-written warn-severity `relationships` test (#141) today; a `where_expression`-scoped `volume_anomalies` on the unknown-member count is a natural follow-on once #140/#141 land. |
| Compliance erasure (one-shot scenario) | hard-delete / anonymize / retain, per-user | **No**, not at realistic drill scale — one user's rows are noise against daily volume/freshness. | Purpose-written singular tests (#143): no erased user's behavioral rows persist; retained transaction rows survive erasure. |
| Schema evolution (one-shot scenario, additive column) | new nullable column on `games` | **No** — not a volume or freshness signal at all; it's a column-shape change. | dbt contract enforcement (#144) failing the build on a breaking change — a structural mechanism, not an anomaly test or a hand-written assertion. |

So, of the seven: **two** (backdated updates, business-key duplicates) are
genuinely caught by this ticket's anomaly tests with no other mechanism
required; the other **five** each need their own purpose-written test or
bespoke monitor, because the fault changes something anomaly detection
(as configured here — row counts and recency, no finer-grained
`where_expression` slicing) cannot see. `freshness_anomalies` as
configured does not map cleanly onto any of the seven classes either — its
practical value is as a general pipeline-health safety net (e.g. a stalled
upstream) that sits alongside, not on top of, the seven-class taxonomy.

### Environments

Environments (**dev**, **staging**, **prod**) are defined in `steam-infra`'s
CONTEXT.md. The dbt-side terms:

- **raw database** — `STEAM_RAW`. Where landing tables arrive. Read by every
  environment, written only by the CDC connector.
- **developer schema** — a layer schema prefixed with the developer's name
  inside `STEAM_DEV` (`dbt_dulain_stg`, `dbt_dulain_marts_core`). Each
  developer's builds are isolated from every other developer's.
- **CI schema** — a layer schema prefixed with the PR number inside
  `STEAM_DEV` (`ci_pr_123_stg`). Created by a PR's CI build, dropped when that
  build finishes.
- Staging and prod use the bare layer schema names (`stg`, `marts_core`) in
  their own databases (`STEAM_STAGING`, `STEAM_PROD`).

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
