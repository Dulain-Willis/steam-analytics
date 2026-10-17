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

Both deployed targets now exist and `scripts/schema_naming_test.sh` asserts
them together — same layer schemas, different database — so "staging is laid
out identically to prod" is checked rather than claimed. The same pair of
target names appears in `dbt_project.yml`'s `on-run-end`, which is what makes
elementary run in the deployed environments and nowhere else; adding a third
deployed environment means editing both.

`scripts/schema_naming_test.sh` asserts all of the above through
`dbt parse`'s manifest, with no Snowflake connection.

## `drop_ci_schema`

Drops every schema a PR's CI build created, in `STEAM_DEV`. Run by
`.github/workflows/ci.yml` as its last step with `if: always()`, so the
schemas go whether the build passed or failed.

"Every schema" is the point. A `ci` build with `DBT_CI_SCHEMA=ci_pr_42` writes
nine of them — `ci_pr_42` (the seed), `ci_pr_42_stg`, `_int`, the four
`_marts_*`, `_elementary`, plus `ci_pr_42_dbt_test__audit` when a test stores
its failures. The macro this replaced dropped `target.schema` alone, i.e. one
of the nine.

The set is "`<prefix>` and anything starting `<prefix>_`", and it is found by
selecting the database's schema names from `information_schema.schemata` and
filtering them in Jinja rather than with `show schemas like`. `_` is a single-character wildcard in SQL `LIKE`, so
`'ci_pr_42_%'` also matches names nobody meant, and `'ci_pr_42%'` without the
separator matches PR 420's schemas — in a statement that is a `DROP`.
Filtering by name has no wildcard semantics to get wrong.

Two guards: the macro refuses to run on any target but `ci` (the same logic
against `dev` would drop a developer's own schemas), and it refuses an empty
prefix (which would match everything). Neither is reachable from the workflow;
they exist for the hand-run case.

`scripts/schema_naming_test.sh` asserts the half of this that needs no
warehouse: that every schema a `ci` build creates is one this filter matches,
and that two PRs whose prefixes share a string prefix (`ci_pr_4`, `ci_pr_42`)
match disjoint sets.
