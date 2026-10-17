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
| `staging` | staging Airflow on EKS | `STEAM_STAGING` | bare layer names |
| `prod` | prod Airflow on EKS | `STEAM_PROD` | bare layer names (`stg`, `int`, `marts_*`) |

Schema naming lives in `macros/generate_schema_name.sql`; see `macros/README.md`
for the full table, and `scripts/schema_naming_test.sh` to check it without a
Snowflake connection.

### CI

All three workflows run as one Snowflake identity: the service user
`STEAM_CI_SVC` with role `CI`, created by steam-infra's `terraform/snowflake`.
It writes `STEAM_DEV` only, reads `STEAM_RAW` and `STEAM_PROD`, and has no
grant whatsoever on `STEAM_STAGING`. Its key pair is regenerated on every
steam-infra bring-up, which pushes three secrets to this repo:
`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER` and `SNOWFLAKE_PRIVATE_KEY`. Nothing
else is a secret — `SNOWFLAKE_ROLE` and `SNOWFLAKE_DATABASE` are literals in
each workflow, because they are fixed names and a stale secret is invisible in
a way a stale literal is not.

| Workflow | Target | Reads / writes |
|---|---|---|
| `ci.yml` (`dbt-run`) | `ci` | writes `STEAM_DEV.ci_pr_<N>_*`; defers unchanged models to `STEAM_PROD` |
| `source-freshness.yml` | `ci` | reads `STEAM_RAW`; writes nothing |
| `update-dbt-artifacts-and-docs.yml` (`serve-dbt-docs`) | `prod` | catalogues `STEAM_PROD` |
| `update-dbt-artifacts-and-docs.yml` (`update-dbt-artifacts`) | `prod` | nothing — `dbt parse` makes no connection |

**Known gap: `fct_source_freshness` has no producer.** `source-freshness.yml`
runs on the `ci` target rather than `prod`, which is a deliberate choice with a
consequence. `dbt source freshness` runs `on-run-end`, and that hook is gated on
the deployed targets — so on `prod` the workflow would call
`elementary.on_run_end()`, which **writes** `STEAM_PROD.elementary`. The CI
identity is read-only on `STEAM_PROD` by design, and the two ways to let it
through are both worse: granting CI write on prod breaks the isolation this
setup exists for, and putting prod's writer key in GitHub secrets restores the
exposure it removed.

The freshness checks themselves are unaffected (sources name their own database,
so the target changes nothing about what is read), but elementary no longer
captures the results, so `models/marts/core/fct_source_freshness.sql` gets no new
rows. Capturing them needs a prod writer, which means the freshness run belongs
in prod Airflow's DAG — where the key never leaves the cluster — rather than in
GitHub Actions. Tracked on steam-infra #121.

Slim CI (`dbt build --select state:modified+ --defer`) resolves an unselected
`ref()` to the relation recorded in the `dbt-manifest` artifact that
`update-dbt-artifacts` publishes. That job parses as the **prod** target
against **`STEAM_PROD`** for exactly that reason, and asserts it on the
artifact before uploading it: a manifest naming any other database makes slim
CI fail in an unrelated PR with "Object does not exist".

Every schema a PR's build created is dropped by
`dbt run-operation drop_ci_schema` on the way out, pass or fail — see
`macros/README.md`.

See `CONTEXT.md` for the domain model and `docs/` for the SQL style guide and
the ADRs.
