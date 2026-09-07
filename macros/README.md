# macros

## `generate_schema_name`

Overrides dbt's default so the schema is the folder-derived name **verbatim**
in every environment (dev, CI, prod) — no target prefix. The folder-to-schema
mapping is declared as `+schema` in `dbt_project.yml`.

Worked example — given `target.schema = "whatever"`:

| Model path | `+schema` config | Resulting schema |
|---|---|---|
| `models/staging/steam/stg_steam__users.sql` | `stg` | `stg` |
| `models/intermediate/int_replay_prices.sql` | `int` | `int` |
| `models/marts/core/dim_users.sql` | `marts_core` | `marts_core` |
| `models/marts/product/fct_dau_wau.sql` | `marts_product` | `marts_product` |
| `models/marts/marketing/fct_cpa.sql` | `marts_marketing` | `marts_marketing` |
| `models/marts/finance/fct_finance_revenue_daily.sql` | `marts_finance` | `marts_finance` |
| elementary package models | `elementary` | `elementary` |
| a model with no `+schema` | _(none)_ | `whatever` (target default) |

Snowflake uppercases unquoted identifiers, so these land physically as `STG`,
`INT`, `MARTS_CORE`, etc.
