{#
    The merge-on-unique-key incremental filter shared by every incremental
    fact in this project (#134 establishes the pattern; #135/#136/#138 reuse
    it). Guards on recorded_at - every stg model's arrival-timestamp column
    (CONTEXT.md), uniformly named, never the model's event-timestamp
    column - so a late-arriving or restated row is rescanned on the next
    run rather than permanently dropped.

    `or is_deleted` (steam-infra#129 integration review, finding 2): a
    rewrite-mode ExtractNewRecordState delete tombstone carries only the
    primary key plus __deleted=true - every other column, recorded_at
    included, is null. `recorded_at >= ...` on a null is never true, so
    without this a hard delete (CDC or #143 compliance erasure) would never
    pass this filter and the already-landed row would keep is_deleted=false
    forever. A delete row is cheap to always let through: the merge just
    upserts is_deleted=true onto its own primary key, same cost as any
    other rescanned row.

    Call only inside `{% if is_incremental() %}`, where `{{ this }}` already
    exists:

        where {{ incremental_lookback_filter() }}

    Pulled out once two models (fct_purchases, fct_ownership_grants) needed
    the identical expression, per docs/style_guide.md's CTE/logic-dedup rule.
#}
{% macro incremental_lookback_filter() %}
    (
        is_deleted
        or recorded_at >= (
            select dateadd('day', -{{ var('arrival_lookback_days') }}, max(recorded_at))  -- noqa: RF02

            from {{ this }}

        )
    )
{% endmacro %}
