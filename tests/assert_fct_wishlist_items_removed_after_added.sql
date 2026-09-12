-- Singular test: a wishlist item can't be removed before it was added.
-- Fails on any row where removed_at is present but predates added_at.

with wishlist_items as (

    select * from {{ ref('fct_wishlist_items') }}

)

select *
from wishlist_items
where removed_at is not null and removed_at < added_at
