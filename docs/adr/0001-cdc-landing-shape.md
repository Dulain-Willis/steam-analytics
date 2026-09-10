# CDC landing shape: flattened and schematized

The `steam-infra` CDC pipeline (RDS → Debezium → Kafka → Snowflake sink) lands
one Snowflake table per source table. We land those tables **flattened and
schematized**: the Debezium source connector runs the `ExtractNewRecordState`
SMT, both connectors set `value.converter.schemas.enable=true`, and the Snowflake
sink sets `snowflake.enable.schematization=true`. Each landing table therefore
has one typed column per source column, a set of `__`-prefixed CDC bookkeeping
columns (`__op`, `__source_ts_ms`, `__source_lsn`, `__source_snapshot`,
`__source_table`, `__source_txid`, `__deleted`), and a `RECORD_METADATA` VARIANT
carrying the Kafka `offset` / `partition` / `topic`. The `stg` layer is then a
thin cast/rename/dedupe over real columns. The connector change is tracked as
issue #28; this ADR records the shape it targets.

## Considered options

- **Raw Debezium envelope** (two VARIANT columns per table, `record_content` /
  `record_metadata`, unwrapped in SQL). Rejected: every staging model becomes
  nested VARIANT-path extraction (`record_content:after:<field>`), the freshness
  `loaded_at_field` is an expression rather than a column, and the shape is
  unidiomatic for an analytics engineer picking up the repo.
- **Avro + Confluent Schema Registry.** Best type fidelity and smallest wire
  size, but adds an always-up Schema Registry component to `steam-infra`, which
  contradicts its teardown-between-sessions discipline (`steam-infra` #27). JSON
  with `schemas.enable=true` carries the schema inline and needs no registry.
- **Schemaless JSON + schematization.** Rejected: with no schema in the message
  the Snowflake connector infers a column's type from the first value it sees and
  never retypes it — a `NULL`-first column is locked to `VARCHAR` forever, even
  across `snapshot.mode=always` re-snapshots.

## Consequences

- **`before` image is gone.** `ExtractNewRecordState` drops it. This costs
  nothing today: all 16 `steam-infra` tables use the default `REPLICA IDENTITY`,
  so `before` already carried only the primary key. Revisiting
  `REPLICA IDENTITY FULL` + real deletes is tracked as a separate enhancement.
- **Type fidelity is partial.** The Snowflake connector honors only
  `org.apache.kafka.connect.data.{Date,Time,Timestamp,Decimal}`, not any
  `io.debezium.*` logical type. Every `steam-infra` column is `timestamptz`
  (Debezium `ZonedTimestamp` → `VARCHAR`) and `jsonb` (→ `VARCHAR`), so `stg`
  still casts those. Native types land for `bigint`, `boolean`, `text[]`,
  `uuid` / `text`.
- **Dedupe key is the Kafka offset**, read from `RECORD_METADATA` (still written
  under schematization), not `__source_lsn` (which is not per-row monotonic on
  snapshot events). `snapshot.mode=always` is unchanged, so `stg` models must
  dedupe on every build.
- **`schemas.enable=true` roughly 2–10×'s the message size.** Acceptable at this
  project's volume and teardown cadence; revisit if throughput becomes the
  constraint.
