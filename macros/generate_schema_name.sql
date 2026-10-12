{#
    Custom schema naming, env-aware (steam-infra #115). Follows dbt's built-in
    generate_schema_name_for_env pattern, but prefixes the *layer* name rather
    than collapsing every layer into target.schema — so the warehouse layout
    mirrors the repo in every environment, with a prefix in the environments
    that share a database.

        target        database        schema of a `+schema: stg` model
        ------------  -------------   --------------------------------
        prod          STEAM_PROD      stg
        staging       STEAM_STAGING   stg
        dev           STEAM_DEV       <target.schema>_stg, e.g. dbt_dulain_stg
        ci            STEAM_DEV       <target.schema>_stg, e.g. ci_pr_42_stg

    Each layer folder sets its own `+schema` in dbt_project.yml (stg, int,
    marts_core, marts_product, marts_marketing, marts_finance, elementary).
    Anything without one — the fx_rates seed — lands in target.schema itself.

    Any target that is not prod or staging prefixes, so a new environment is
    sandboxed by default rather than by remembering to add it here. That is
    also why this branch needed no change when steam-infra #119 added the
    `staging` target — it was written for both targets up front, and
    scripts/schema_naming_test.sh asserts the two produce identical layer
    schemas in their own databases.

    The same pair of target names appears in dbt_project.yml's `on-run-end`,
    which is what runs elementary in the deployed environments and nowhere
    else. A third deployed environment has to be added to both, or elementary
    silently stops running there.

    The prefix is required, not defaulted: a target that prefixes with nothing
    would write the bare layer names into whatever database it points at,
    which is the "CI overwrites production" bug #112 exists to fix. env_var()
    raises on an unset variable but not on an empty one, so the check lives
    here rather than in profiles.yml — this is the one place that sees the
    final value, whatever set it.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set layer = custom_schema_name | trim if custom_schema_name is not none else none -%}

    {%- if target.name in ('prod', 'staging') -%}
        {{ layer if layer is not none else target.schema }}

    {%- else -%}
        {%- set prefix = target.schema | trim -%}
        {%- if not prefix -%}
            {{ exceptions.raise_compiler_error(
                "target '" ~ target.name ~ "' builds into prefixed schemas, but its schema is empty."
                ~ " Set SNOWFLAKE_SCHEMA to your developer schema (e.g. SNOWFLAKE_SCHEMA=dbt_dulain)"
                ~ " for the dev target, or DBT_CI_SCHEMA for the ci target. See README.md.") }}
        {%- endif -%}
        {{ prefix if layer is none else prefix ~ "_" ~ layer }}
    {%- endif -%}

{%- endmacro %}
