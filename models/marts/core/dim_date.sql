-- dim_date: date spine over the project's active window (see CONTEXT.md).
-- No joins to other models — pure calendar generation.

with date_spine as (

    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="to_date('" ~ var('dim_date_start_date') ~ "')",
        end_date="to_date('" ~ var('dim_date_end_date') ~ "')"
    ) }}

),

final as (

    select
        date_day::date as date_day,
        year(date_day) as year,
        quarter(date_day) as quarter,
        month(date_day) as month,
        day(date_day) as day_of_month,
        dayofweek(date_day) as day_of_week,
        dayname(date_day) as day_name,
        weekofyear(date_day) as week_of_year,
        (dayofweek(date_day) in (0, 6)) as is_weekend

    from date_spine

)

select * from final
