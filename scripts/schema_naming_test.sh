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

# --- 3. the deployed environments: bare layer schema names -----------------
#
# One loop over staging and prod rather than two blocks, because "staging is a
# faithful copy of prod's layout" is the AC: anything asserted of one and not
# the other is a way for the two to drift. The *only* difference permitted is
# the database, which is why that is the loop variable.
#
# This is also where #115's claim that the macro was "already correct when
# staging exists" gets checked rather than taken on trust.

for env in staging prod; do
  db=$([[ $env == staging ]] && echo STEAM_STAGING || echo STEAM_PROD)
  out=$(parse "$env" SNOWFLAKE_DATABASE="$db" SNOWFLAKE_SCHEMA="$env")
  check "$env target parses" "$?" "$out"
  built=$(relations "$WORK/$env/manifest.json")

  expected=$(
    printf '%s\n' elementary int marts_core marts_finance \
      marts_marketing marts_product "$env" stg | sed "s|^|$db.|" | sort
  )
  check "$env builds exactly the bare layer schemas in $db" \
    "$([[ "$(sort <<<"$built")" == "$expected" ]] && echo 0 || echo 1)" \
    "$(diff <(sort <<<"$built") <(echo "$expected"))"

  # The other direction, and the one the grant check cannot see: a staging
  # build must name nothing in prod's database, and vice versa.
  others=$(grep -vE "^$db\." <<<"$built")
  check "$env writes nothing outside $db" \
    "$([[ -z "$others" ]] && echo 0 || echo 1)" "$others"

  srcs=$(jq -r '[.sources[] | .database] | unique | .[]' "$WORK/$env/manifest.json")
  check "$env reads sources from STEAM_RAW" \
    "$([[ "$srcs" == "STEAM_RAW" ]] && echo 0 || echo 1)" "$srcs"
done

# And the two are the same layout, not merely each self-consistent: the same
# schema names in different databases. Compared by stripping the database, so
# a layer that exists in prod and not staging fails here even though both
# blocks above passed.
staging_layers=$(relations "$WORK/staging/manifest.json" | sed 's/^STEAM_STAGING\.//' | grep -v '^staging$' | sort)
prod_layers=$(relations "$WORK/prod/manifest.json" | sed 's/^STEAM_PROD\.//' | grep -v '^prod$' | sort)
check "staging and prod build the same layer schemas" \
  "$([[ "$staging_layers" == "$prod_layers" ]] && echo 0 || echo 1)" \
  "$(diff <(echo "$staging_layers") <(echo "$prod_layers"))"

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
