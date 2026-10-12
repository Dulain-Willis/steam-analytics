# macros

## `generate_schema_name`

Overrides dbt's default with **env-aware** naming (dbt's
`generate_schema_name_for_env` pattern, prefixing the layer rather than
collapsing every layer into one schema):

- the **`prod`** and **`staging`** targets use the folder-derived name
  verbatim, so `STEAM_PROD` and `STEAM_STAGING` are laid out identically;
- every other target — **`dev`**, **`ci`** — prefixes it with `target.schema`,
  so a developer's build and a PR's build each get their own set of schemas
  inside the shared `STEAM_DEV` database.

The folder-to-schema mapping is declared as `+schema` in `dbt_project.yml`.
`target.schema` is `SNOWFLAKE_SCHEMA` on the dev target (your developer schema,
e.g. `dbt_dulain`) and `DBT_CI_SCHEMA` on the ci target (`ci_pr_<N>`).

Worked example:

| Model path | `+schema` config | `prod` / `staging` | `dev` with `SNOWFLAKE_SCHEMA=dbt_dulain` |
|---|---|---|---|
| `models/staging/steam/stg_steam__users.sql` | `stg` | `stg` | `dbt_dulain_stg` |
| `models/intermediate/int_replay_prices.sql` | `int` | `int` | `dbt_dulain_int` |
| `models/marts/core/dim_users.sql` | `marts_core` | `marts_core` | `dbt_dulain_marts_core` |
| `models/marts/product/fct_dau_wau.sql` | `marts_product` | `marts_product` | `dbt_dulain_marts_product` |
| `models/marts/marketing/fct_cpa.sql` | `marts_marketing` | `marts_marketing` | `dbt_dulain_marts_marketing` |
| `models/marts/finance/fct_finance_revenue_daily.sql` | `marts_finance` | `marts_finance` | `dbt_dulain_marts_finance` |
| elementary package models | `elementary` | `elementary` | `dbt_dulain_elementary` |
| `seeds/fx_rates.csv` (no `+schema`) | _(none)_ | target default | `dbt_dulain` |

Snowflake uppercases unquoted identifiers, so these land physically as `STG`,
`DBT_DULAIN_STG`, etc.

The prefix is **required** on a prefixing target — neither `SNOWFLAKE_SCHEMA`
nor `DBT_CI_SCHEMA` has a default: the macro raises a compiler error naming
them when `target.schema` is empty, rather than
writing the bare layer names into whatever database the target points at.
`env_var()` already raises when the variable is unset, but not when it is set
to the empty string, so the check lives in the macro where the final value is
visible.

The `staging` target does not exist yet (steam-infra #119 adds it); the macro
treats it as a bare-name target already.

`scripts/schema_naming_test.sh` asserts all of the above through
`dbt parse`'s manifest, with no Snowflake connection.
