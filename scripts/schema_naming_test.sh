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
#    are tested, for both prefixing targets — see check_parse_fails, which also
#    asserts *which* variable the error names rather than only that there was
#    one.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The repo's convention (CLAUDE.md) is `uv run dbt`, which does not resolve in
# a plain clone or a git worktree — so prefer the checkout's own .venv when it
# has one, and let DBT="path/to/dbt" override either.
if [[ -z "${DBT:-}" && -x "$PROJECT_DIR/.venv/bin/dbt" ]]; then
  DBT="$PROJECT_DIR/.venv/bin/dbt"
fi
read -ra DBT_CMD <<<"${DBT:-uv run dbt}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Before any assertion: the dbt under test actually runs. Half the scenarios
# below assert that a parse *fails*, so a dbt that cannot run at all satisfies
# them for the wrong reason — and "the documented invocation does not resolve"
# is exactly how that happens. Fail here, with the fix, rather than reporting
# a screenful of green.
if ! "${DBT_CMD[@]}" --version >/dev/null 2>&1; then
  printf 'FAIL  "%s" does not run. Set DBT to a working dbt, e.g.\n' "${DBT_CMD[*]}" >&2
  printf '      DBT="%s/.venv/bin/dbt" %s\n' "$PROJECT_DIR" "${BASH_SOURCE[0]}" >&2
  exit 1
fi

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

# check_parse_fails NAME VAR MARKER TARGET [VAR=VALUE...] — the parse must
# fail, the error must name VAR, and it must be MARKER's error and not some
# other one.
#
# One check rather than three, because the halves are not separable. "It exited
# non-zero" on its own is satisfied by a broken dbt, a missing package or a
# syntax error in any model — a test asserting "this fails" passing because an
# earlier step broke. And the variable's name on its own does not distinguish
# the two ways a prefix can be absent, which are handled in two different
# places:
#
#   unset  -> profiles.yml's env_var() raises    "Env var required but not provided"
#   empty  -> generate_schema_name's guard raises "Compilation Error in macro
#                                                  generate_schema_name"
#
# env_var() does not raise on an empty string, which is the whole reason the
# macro carries a guard at all (#115). Asserting only the variable name lets
# the empty scenario pass on env_var's error, i.e. with that guard untested —
# so each call site names the error it expects.
check_parse_fails() {
  local name="$1" var="$2" marker="$3" out status
  shift 3
  out=$(parse "$@")
  status=$?
  if ((status == 0)); then
    check "$name" 1 "the parse succeeded — it must fail"
  elif ! grep -qF "$marker" <<<"$out"; then
    check "$name" 1 "the parse failed, but not with \"$marker\":
$out"
  else
    check "$name" "$(grep -qF "$var" <<<"$out" && echo 0 || echo 1)" \
      "the parse failed with the right error, but it does not name $var:
$out"
  fi
}

# The two ways a required prefix can be absent, and which code rejects each.
ENV_VAR_ERROR="Env var required but not provided"
MACRO_GUARD_ERROR="Compilation Error in macro generate_schema_name"

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

check_parse_fails "an empty developer schema hits the macro guard, naming SNOWFLAKE_SCHEMA" \
  SNOWFLAKE_SCHEMA "$MACRO_GUARD_ERROR" dev SNOWFLAKE_DATABASE=STEAM_DEV SNOWFLAKE_SCHEMA=

# No SNOWFLAKE_SCHEMA= at all. `env` only adds variables, and parse() runs
# from a scratch cwd, so this really is unset — a `.env` in the checkout would
# otherwise make this scenario lie.
check_parse_fails "an unset developer schema is rejected by env_var, naming SNOWFLAKE_SCHEMA" \
  SNOWFLAKE_SCHEMA "$ENV_VAR_ERROR" dev SNOWFLAKE_DATABASE=STEAM_DEV

# --- 5. ci: a PR's build lands only in its own CI schemas ------------------
#
# steam-infra #116's first AC — "the CI build writes only ci_pr_<N>_* schemas
# in STEAM_DEV, and no non-CI schema is modified" — read off the manifest. The
# live half of that AC (a real PR, a real warehouse) is the orchestrator's
# gate; this is the half that can be proven without one, and it is the half
# that regresses when someone edits the macro.

out=$(parse ci SNOWFLAKE_DATABASE=STEAM_DEV DBT_CI_SCHEMA=ci_pr_42)
check "ci target parses" "$?" "$out"
ci=$(relations "$WORK/ci/manifest.json")
stray=$(grep -v '^STEAM_DEV\.ci_pr_42' <<<"$ci")
check "ci builds only into STEAM_DEV.ci_pr_42_*" \
  "$([[ -z "$stray" ]] && echo 0 || echo 1)" "$stray"

leaks=$(grep -E '^(STEAM_STAGING|STEAM_PROD|STEAM_RAW)\.' <<<"$ci")
check "ci writes nothing in STEAM_STAGING, STEAM_PROD or STEAM_RAW" \
  "$([[ -z "$leaks" ]] && echo 0 || echo 1)" "$leaks"

srcs=$(jq -r '[.sources[] | .database] | unique | .[]' "$WORK/ci/manifest.json")
check "ci reads sources from STEAM_RAW" \
  "$([[ "$srcs" == "STEAM_RAW" ]] && echo 0 || echo 1)" "$srcs"

# The same layers as prod, in STEAM_DEV behind a prefix — #112 story 8, and
# what makes a CI build a faithful rehearsal rather than a different shape.
# The bare `ci_pr_42` (the seed) strips to an empty line and is dropped, the
# same way section 3 drops prod's bare `prod`.
pr42=${ci//STEAM_DEV./}
ci_layers=${pr42//ci_pr_42_/}
ci_layers=$(grep -v '^$' <<<"${ci_layers//ci_pr_42/}" | sort)
check "ci builds the same layer schemas as prod" \
  "$([[ "$ci_layers" == "$prod_layers" ]] && echo 0 || echo 1)" \
  "$(diff <(echo "$ci_layers") <(echo "$prod_layers"))"

# --- 6. every CI schema is one macros/drop_ci_schema.sql will drop ----------
#
# The second AC — "no ci_pr_<N>_* schema remains afterwards" — is really two
# claims, and only one of them is about the drop. The other is this one: every
# schema the build creates is named so that the macro's filter matches it.
# The macro drops exactly `<prefix>` and `<prefix>_*`, so a layer that landed
# anywhere else would survive, and nothing in the macro could notice.
#
# This is the check that would have caught the bug as it actually shipped: the
# old macro dropped target.schema alone, which is one of the nine schemas
# below.
unmatched=$(grep -vE '^ci_pr_42(_|$)' <<<"$pr42")
check "every ci schema is ci_pr_42 or ci_pr_42_*, so the drop macro matches it" \
  "$([[ -z "$unmatched" ]] && echo 0 || echo 1)" "$unmatched"

# And the trap the macro's comment is about: one PR's prefix must not match
# another's schemas. `ci_pr_4` is a prefix of `ci_pr_42` as a *string*, so a
# `like 'ci_pr_4%'` drop would take PR 42's schemas with it. Requiring the
# separator — `ci_pr_4` itself, or `ci_pr_4_` — is what makes the two disjoint.
out=$(parse ci SNOWFLAKE_DATABASE=STEAM_DEV DBT_CI_SCHEMA=ci_pr_4)
check "a second PR's ci target parses" "$?" "$out"
pr4=$(relations "$WORK/ci/manifest.json")
pr4=${pr4//STEAM_DEV./}
collisions=$(grep -xE 'ci_pr_4(_.*)?' <<<"$pr42")
check "PR 4's drop pattern matches none of PR 42's schemas" \
  "$([[ -z "$collisions" ]] && echo 0 || echo 1)" "$collisions"
shared=$(comm -12 <(sort <<<"$pr4") <(sort <<<"$pr42"))
check "two PRs share no schema" \
  "$([[ -z "$shared" ]] && echo 0 || echo 1)" "$shared"

# --- 7. the ci prefix is required, not defaulted ---------------------------

check_parse_fails "an unset CI schema is rejected by env_var, naming DBT_CI_SCHEMA" \
  DBT_CI_SCHEMA "$ENV_VAR_ERROR" ci SNOWFLAKE_DATABASE=STEAM_DEV

check_parse_fails "an empty CI schema hits the macro guard, naming DBT_CI_SCHEMA" \
  DBT_CI_SCHEMA "$MACRO_GUARD_ERROR" ci SNOWFLAKE_DATABASE=STEAM_DEV DBT_CI_SCHEMA=

# --- 8. slim-CI deferral: what the published manifest names -----------------
#
# `dbt build --defer --state state` rewrites an unselected ref() to the
# relation recorded in the manifest that update-dbt-artifacts publishes. Now
# that the ci target prefixes, deferral genuinely fires — unselected upstream
# models are not in the current target — so that manifest's relations are the
# ones CI actually reads, and they have to be prod's (#112's Q1: they used to
# be `dummy.*`, which nobody noticed because deferral never fired).
#
# dbt parse makes no connection, so the fix is two env values and they are
# checkable here: parse with exactly what that job sets and assert the result.

out=$(parse prod SNOWFLAKE_DATABASE=STEAM_PROD)
check "the manifest job's target and database parse" "$?" "$out"
deferred=$(relations "$WORK/prod/manifest.json")
stray=$(grep -v '^STEAM_PROD\.' <<<"$deferred")
check "the published manifest's relations are all in STEAM_PROD" \
  "$([[ -z "$stray" ]] && echo 0 || echo 1)" "$stray"

# The values above are a copy of the workflow's, so they are only a proof
# while they still match it. Two greps rather than a YAML parse: the workflow
# asserts the same property on the real artifact at run time (its "Assert the
# manifest's relations are prod's" step), and this is just the tripwire for
# editing the env block without noticing what it is for.
WORKFLOWS="$PROJECT_DIR/.github/workflows"
MANIFEST_WF="$WORKFLOWS/update-dbt-artifacts-and-docs.yml"
for pair in "DBT_TARGET: prod" "SNOWFLAKE_DATABASE: STEAM_PROD"; do
  check "update-dbt-artifacts-and-docs.yml sets $pair" \
    "$(grep -qF "      $pair" "$MANIFEST_WF" && echo 0 || echo 1)" \
    "$(grep -nE 'DBT_TARGET|SNOWFLAKE_DATABASE' "$MANIFEST_WF")"
done

# And the identity half (#116): role and database are literals in every
# workflow, never secrets. A secret that goes stale is invisible — #114
# renamed STEAM_PROJECT and the SNOWFLAKE_DATABASE secret went on naming it,
# which is what broke ci.yml's dbt-run job — while a wrong literal is in the
# diff. Only the account, the CI service user and its key are secrets now.
stale=$(grep -rnE 'secrets\.SNOWFLAKE_(ROLE|DATABASE|WAREHOUSE)' "$WORKFLOWS" || true)
check "no workflow reads the role, database or warehouse from a secret" \
  "$([[ -z "$stale" ]] && echo 0 || echo 1)" "$stale"

# --- 9. the committed example cannot hand two developers one schema ---------
#
# SNOWFLAKE_SCHEMA lost its default so that a developer who has not set one
# fails instead of writing somewhere shared. A *placeholder* in .env.example
# puts the default straight back: two people who copied the file and did not
# reach that line would both build into the placeholder's schemas, silently —
# the exact collision the guard exists for, reintroduced by documentation.
example_schema=$(grep -E '^SNOWFLAKE_SCHEMA=' "$PROJECT_DIR/.env.example" || true)
check ".env.example ships SNOWFLAKE_SCHEMA empty, not a working placeholder" \
  "$([[ "$example_schema" == "SNOWFLAKE_SCHEMA=" ]] && echo 0 || echo 1)" \
  "found: ${example_schema:-no SNOWFLAKE_SCHEMA line at all}"

if ((failures)); then
  printf '\n%d check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall checks passed\n'
