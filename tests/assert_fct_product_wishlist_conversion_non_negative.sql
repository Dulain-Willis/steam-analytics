-- Singular test (issue #19): every measure on
-- fct_product_wishlist_conversion must be non-negative, and conversion_rate
-- (a share of wishlist_add_count) can never exceed 1.

with wishlist_conversion as (

    select * from {{ ref('fct_product_wishlist_conversion') }}

)

select *
from wishlist_conversion
where
    wishlist_add_count < 0
    or converted_count < 0
    or conversion_rate < 0
    or conversion_rate > 1
    or median_days_to_convert < 0
