# steam-analytics

The dbt project behind the steam pipeline. dbt docs (GitHub Pages):
https://dulain-willis.github.io/steam-analytics/

## Developer setup

You need no Airflow to work on models. Everything you build lands in **your
own developer schemas** inside the shared `STEAM_DEV` database, so two people
can build the same model at the same time and get two separate tables.

1. **Get a Snowflake developer user.** The operator adds you to the
   `developers` list in steam-infra's `terraform/snowflake/variables.tf` — one
   entry, your name and your RSA public key — and the next bring-up creates
   `STEAM_DEV_<YOURNAME>` with the `DEVELOPER` role. Generate the key pair
   first and hand over the public half:

   ```sh
   openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out ~/.dbt/snowflake_key.p8
   chmod 600 ~/.dbt/snowflake_key.p8
   openssl rsa -in ~/.dbt/snowflake_key.p8 -pubout | grep -v '^-----' | tr -d '\n'
   ```

2. **Fill in `.env`.** `cp .env.example .env` and set your values — the one
   that matters is `SNOWFLAKE_SCHEMA`, your developer schema prefix
   (`dbt_<yourname>`). It is required: dbt refuses to run without it rather
   than writing somewhere shared. `.envrc` is one line (`dotenv`), so direnv
   loads `.env` on `cd`; without direnv, `set -a; . ./.env; set +a`.

3. **Install and run.**

   ```sh
   uv venv
   uv pip install -r requirements.txt
   uv run dbt deps
   uv run dbt build
   ```

   `dbt build` runs models, tests, seeds and snapshots on the `dev` target —
   `uv run dbt build --select stg_steam__users+` while iterating. Run every
   Python tool here through `uv run` (see `CLAUDE.md`).

### What gets created where

With `SNOWFLAKE_SCHEMA=dbt_dulain`, a `dbt build` on the dev target creates,
in `STEAM_DEV` only:

| Layer | Schema |
|---|---|
| stg layer (`models/staging/`) | `DBT_DULAIN_STG` |
| intermediate | `DBT_DULAIN_INT` |
| marts | `DBT_DULAIN_MARTS_CORE`, `_MARTS_PRODUCT`, `_MARTS_MARKETING`, `_MARTS_FINANCE` |
| elementary package | `DBT_DULAIN_ELEMENTARY` |
| the `fx_rates` seed | `DBT_DULAIN` |

Sources are read from the CDC landing tables in `STEAM_RAW.STEAM_RDS`, which
only steam-infra's Kafka sink writes. `DEVELOPER` can read `STEAM_RAW` and
write `STEAM_DEV`, and has no grant at all on `STEAM_STAGING` or `STEAM_PROD`
— a mistake in dev cannot reach staging or prod data, by grants rather than by
convention.

### Environments

| Target | Runs | Database | Schemas |
|---|---|---|---|
| `dev` | your machine, with or without local Airflow | `STEAM_DEV` | `<SNOWFLAKE_SCHEMA>_<layer>` |
| `ci` | a PR's build | `STEAM_DEV` | `ci_pr_<N>_<layer>` |
| `prod` | prod Airflow on EKS | `STEAM_PROD` | bare layer names (`stg`, `int`, `marts_*`) |

Schema naming lives in `macros/generate_schema_name.sql`; see `macros/README.md`
for the full table, and `scripts/schema_naming_test.sh` to check it without a
Snowflake connection.

See `CONTEXT.md` for the domain model and `docs/` for the SQL style guide and
the ADRs.
