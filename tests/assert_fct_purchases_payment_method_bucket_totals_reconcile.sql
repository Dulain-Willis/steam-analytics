-- Singular test (#139): payment_method_bucket must never lose rows. A case
-- expression with no else would null out an unrecognized payment_method and
-- (depending on how a downstream breakdown groups/filters) could drop those
-- rows out of every bucket. This compares the row count summed across
-- payment_method_bucket groups to fct_purchases' unbucketed total -- any
-- mismatch (including bucket is null) fails the test.
with

purchases as (

    select * from {{ ref('fct_purchases') }}

),

unbucketed_total as (

    select count(*) as total_count

    from purchases

),

bucket_counts as (

    select
        payment_method_bucket,
        count(*) as bucket_count

    from purchases

    group by 1

),

bucketed_total as (

    select sum(bucket_count) as total_count

    from bucket_counts

),

totals as (

    select
        unbucketed_total.total_count as unbucketed_count,
        bucketed_total.total_count as bucketed_count

    from unbucketed_total

    cross join bucketed_total

)

select *

from totals

where unbucketed_count != bucketed_count
    or bucketed_count is null
