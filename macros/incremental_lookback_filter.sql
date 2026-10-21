{#
    The merge-on-unique-key incremental filter shared by every incremental
    fact in this project (#134 establishes the pattern; #135/#136/#138 reuse
    it). Guards on recorded_at - every stg model's arrival-timestamp column
    (CONTEXT.md), uniformly named, never the model's event-timestamp
    column - so a late-arriving or restated row is rescanned on the next
    run rather than permanently dropped.

    Call only inside `{% if is_incremental() %}`, where `{{ this }}` already
    exists:

        where {{ incremental_lookback_filter() }}

    Pulled out once two models (fct_purchases, fct_ownership_grants) needed
    the identical expression, per docs/style_guide.md's CTE/logic-dedup rule.
#}
{% macro incremental_lookback_filter() %}
    recorded_at >= (
        select dateadd('day', -{{ var('arrival_lookback_days') }}, max(recorded_at))  -- noqa: RF02

        from {{ this }}

    )
{% endmacro %}
