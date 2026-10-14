-- Temporary CI probe (deliberately failing) for steam-infra #112 step 4.
-- Proves the CI schema drop runs on failure too (if: always()).
-- Delete once the acceptance run is recorded.
select 1 as probe from this_relation_does_not_exist
