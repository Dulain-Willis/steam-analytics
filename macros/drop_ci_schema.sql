{#
    Drops every schema a PR's CI build created. Run by .github/workflows/ci.yml
    as its last step, with `if: always()`, so the schemas go whether the build
    passed or failed (#112 story 18).

    A `ci` build does not write one schema, it writes one per layer:
    DBT_CI_SCHEMA=ci_pr_42 yields ci_pr_42_stg, _int, _marts_core,
    _marts_product, _marts_marketing, _marts_finance, _elementary, plus
    ci_pr_42 itself (the fx_rates seed, which configures no +schema) and
    ci_pr_42_dbt_test__audit when a test stores its failures. The old macro
    dropped `target.schema` alone — ci_pr_42 — and left every layer behind,
    which is half of why #112 exists.

    So the set to drop is "ci_pr_42 and anything starting ci_pr_42_". That is
    deliberately *not* expressed as `show schemas like 'ci_pr_42_%'`:

      - `_` is a single-character wildcard in SQL LIKE, so that pattern also
        matches ciXprY42Z… (#112's Q7.11), and this statement is a DROP.
      - Escaping it (`ci\_pr\_42\_%`) then depends on how Snowflake's string
        literal parser and LIKE each treat the backslash — two layers of
        quoting to get right in a destructive statement.
      - And `like 'ci_pr_42%'` with no trailing underscore would match
        ci_pr_420_stg, i.e. another PR's schemas.

    Listing the database's schemas and filtering the names in Jinja has no
    wildcard semantics at all, so none of those three questions arises. The
    comparison is case-folded because Snowflake returns unquoted identifiers
    uppercased while the prefix arrives lowercase.

    Guarded on target.name as well: run against dev by accident and the same
    logic would drop a developer's own schemas.
#}
{% macro drop_ci_schema() %}

    {%- if target.name != 'ci' -%}
        {{ exceptions.raise_compiler_error(
            "drop_ci_schema drops every schema sharing target.schema's prefix, which is"
            ~ " only safe for the ci target. The target here is '" ~ target.name ~ "'."
            ~ " Set DBT_TARGET=ci (and DBT_CI_SCHEMA=ci_pr_<N>) to run it.") }}
    {%- endif -%}

    {%- set prefix = target.schema | trim | lower -%}
    {%- if not prefix -%}
        {{ exceptions.raise_compiler_error(
            "drop_ci_schema has no schema prefix to match: the ci target's schema is empty."
            ~ " Set DBT_CI_SCHEMA to the PR's prefix (e.g. DBT_CI_SCHEMA=ci_pr_42).") }}
    {%- endif -%}

    {%- set found = run_query("show terse schemas in database " ~ target.database) -%}

    {%- if execute -%}
        {%- set dropped = [] -%}
        {%- for name in found.columns['name'].values() -%}
            {%- set folded = name | lower -%}
            {%- if folded == prefix or folded.startswith(prefix ~ '_') -%}
                {%- do run_query("drop schema if exists " ~ target.database ~ "." ~ name ~ " cascade") -%}
                {%- do dropped.append(name) -%}
            {%- endif -%}
        {%- endfor -%}

        {%- if dropped -%}
            {{ log("Dropped " ~ dropped | length ~ " CI schema(s) in " ~ target.database
                   ~ ": " ~ dropped | join(", "), info=True) }}
        {%- else -%}
            {#
                Not an error: a build that failed before creating anything
                leaves nothing to drop, and this step runs with if: always().
            #}
            {{ log("No schemas named " ~ prefix ~ " or " ~ prefix ~ "_* in "
                   ~ target.database ~ " — nothing to drop.", info=True) }}
        {%- endif -%}
    {%- endif -%}

{% endmacro %}
