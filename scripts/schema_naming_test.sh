#!/usr/bin/env bash
# Proves what schema every model lands in, per target, without touching
# Snowflake. Run it directly:
#
#     scripts/schema_naming_test.sh
#
# Why this exists: generate_schema_name decides whether a build writes into a
# developer's own schemas or straight into prod's, and that is the one bug
# steam-infra #112 exists to fix. `dbt parse` resolves every node's final
# database.schema.identifier into target/manifest.json without connecting, so
# the whole contract is checkable locally and in CI.
#
# Two traps this script works around deliberately:
#
#  - dbt loads a .env from the current working directory and its parents
#    (`load_dotenv(find_dotenv(usecwd=True))`), and a developer's checkout has
#    one. Every parse therefore runs from a scratch directory with
#    --project-dir/--profiles-dir, so the environment under test is exactly the
#    variables set here and nothing else.
#  - env_var() raises on an *unset* variable but not on an empty one, so both
#    are tested (scenarios 5 and 6).
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The repo's convention (CLAUDE.md) is `uv run dbt`; override with
# DBT="path/to/dbt" to use a dbt that is already on the path.
read -ra DBT_CMD <<<"${DBT:-uv run dbt}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() {
  local name="$1" status="$2" detail="${3:-}"
  if [[ "$status" == 0 ]]; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s\n%s\n' "$name" "$detail"
    failures=$((failures + 1))
  fi
}

# parse TARGET [VAR=VALUE...] — `dbt parse` from a scratch cwd. Prints dbt's
# own output; the manifest lands in $WORK/<target>.
parse() {
  local target="$1"
  shift
  (
    cd "$WORK" || exit 1
    env DBT_TARGET="$target" \
      SNOWFLAKE_ACCOUNT=test-account \
      SNOWFLAKE_USER=test-user \
      SNOWFLAKE_ROLE=TEST_ROLE \
      SNOWFLAKE_PRIVATE_KEY_PATH=/dev/null \
      SNOWFLAKE_PRIVATE_KEY=none \
      "$@" \
      "${DBT_CMD[@]}" parse --quiet --project-dir "$PROJECT_DIR" --profiles-dir "$PROJECT_DIR" \
      --target-path "$WORK/$target" 2>&1
  )
}

# relations [MANIFEST] — every built node's "DATABASE.SCHEMA", sorted unique.
# Models and seeds only: those are what a build writes. Sources are asserted
# separately.
relations() {
  jq -r '[.nodes[] | select(.resource_type == "model" or .resource_type == "seed")
          | .database + "." + .schema] | unique | .[]' "$1"
}

# --- 1. dev: one developer's own schemas inside STEAM_DEV -------------------

out=$(parse dev SNOWFLAKE_DATABASE=STEAM_DEV SNOWFLAKE_SCHEMA=dbt_alice)
check "dev target parses" "$?" "$out"
alice=$(relations "$WORK/dev/manifest.json")

stray=$(grep -v '^STEAM_DEV\.dbt_alice' <<<"$alice")
check "dev builds only into STEAM_DEV.dbt_alice_*" \
  "$([[ -z "$stray" ]] && echo 0 || echo 1)" "$stray"

for schema in dbt_alice_stg dbt_alice_int dbt_alice_marts_core dbt_alice_elementary; do
  check "dev produces STEAM_DEV.$schema" \
    "$(grep -qxF "STEAM_DEV.$schema" <<<"$alice" && echo 0 || echo 1)" "$alice"
done

# "A dev build changes nothing in STEAM_STAGING, STEAM_PROD or STEAM_RAW" —
# the write side. Sources are the only thing pointed at the raw database, and
# they are read-only by construction.
leaks=$(grep -E '^(STEAM_STAGING|STEAM_PROD|STEAM_RAW)\.' <<<"$alice")
check "dev writes nothing in STEAM_STAGING, STEAM_PROD or STEAM_RAW" \
  "$([[ -z "$leaks" ]] && echo 0 || echo 1)" "$leaks"

sources=$(jq -r '[.sources[] | .database] | unique | .[]' "$WORK/dev/manifest.json")
check "dev reads sources from STEAM_RAW" \
  "$([[ "$sources" == "STEAM_RAW" ]] && echo 0 || echo 1)" "$sources"

# --- 2. two developers, two separate sets of schemas ------------------------

out=$(parse dev SNOWFLAKE_DATABASE=STEAM_DEV SNOWFLAKE_SCHEMA=dbt_bob)
check "second developer's target parses" "$?" "$out"
bob=$(relations "$WORK/dev/manifest.json")

shared=$(comm -12 <(sort <<<"$alice") <(sort <<<"$bob"))
check "two developer schema settings share no schema" \
  "$([[ -z "$shared" ]] && echo 0 || echo 1)" "$shared"
check "the two sets are the same size" \
  "$([[ "$(wc -l <<<"$alice")" == "$(wc -l <<<"$bob")" ]] && echo 0 || echo 1)" \
  "alice: $(wc -l <<<"$alice") bob: $(wc -l <<<"$bob")"

# --- 3. prod: bare layer schema names in STEAM_PROD ------------------------

out=$(parse prod SNOWFLAKE_DATABASE=STEAM_PROD SNOWFLAKE_SCHEMA=prod)
check "prod target parses" "$?" "$out"
prod=$(relations "$WORK/prod/manifest.json")

expected_prod=$(
  printf 'STEAM_PROD.%s\n' elementary int marts_core marts_finance \
    marts_marketing marts_product prod stg | sort
)
check "prod builds exactly the bare layer schemas in STEAM_PROD" \
  "$([[ "$(sort <<<"$prod")" == "$expected_prod" ]] && echo 0 || echo 1)" \
  "$(diff <(sort <<<"$prod") <(echo "$expected_prod"))"

# The staging target does not exist yet — steam-infra #119 adds it — so the
# macro's bare-name branch is asserted here through prod only. When staging
# lands, add it to this block: the macro already treats the two alike.

# --- 4. the dev schema is required, not defaulted --------------------------

out=$(parse dev SNOWFLAKE_DATABASE=STEAM_DEV SNOWFLAKE_SCHEMA=)
status=$?
check "an empty developer schema fails the parse" \
  "$([[ $status -ne 0 ]] && echo 0 || echo 1)" "$out"
check "the empty-schema error names SNOWFLAKE_SCHEMA" \
  "$(grep -q SNOWFLAKE_SCHEMA <<<"$out" && echo 0 || echo 1)" "$out"

# No SNOWFLAKE_SCHEMA= at all. `env` only adds variables, and parse() runs
# from a scratch cwd, so this really is unset — a `.env` in the checkout would
# otherwise make this scenario lie.
out=$(parse dev SNOWFLAKE_DATABASE=STEAM_DEV)
status=$?
check "an unset developer schema fails the parse" \
  "$([[ $status -ne 0 ]] && echo 0 || echo 1)" "$out"
check "the unset-schema error names SNOWFLAKE_SCHEMA" \
  "$(grep -q SNOWFLAKE_SCHEMA <<<"$out" && echo 0 || echo 1)" "$out"

# --- 5. ci prefixes too, and its prefix is required as well ----------------
#
# The ci target's schemas are steam-infra #116's, but it shares this macro and
# lost its own `ci` default here, so both halves are asserted now.

out=$(parse ci SNOWFLAKE_DATABASE=STEAM_DEV DBT_CI_SCHEMA=ci_pr_42)
check "ci target parses" "$?" "$out"
ci=$(relations "$WORK/ci/manifest.json")
stray=$(grep -v '^STEAM_DEV\.ci_pr_42' <<<"$ci")
check "ci builds only into STEAM_DEV.ci_pr_42_*" \
  "$([[ -z "$stray" ]] && echo 0 || echo 1)" "$stray"

out=$(parse ci SNOWFLAKE_DATABASE=STEAM_DEV)
status=$?
check "an unset CI schema fails the parse" \
  "$([[ $status -ne 0 ]] && echo 0 || echo 1)" "$out"
check "the unset-CI-schema error names DBT_CI_SCHEMA" \
  "$(grep -q DBT_CI_SCHEMA <<<"$out" && echo 0 || echo 1)" "$out"

if ((failures)); then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall checks passed\n'
