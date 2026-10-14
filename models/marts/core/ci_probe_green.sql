-- Temporary CI probe for steam-infra #112's cold acceptance run (step 4).
-- Verifies a PR build lands only in ci_pr_<N>_* schemas inside STEAM_DEV.
-- Delete once the acceptance run is recorded.
select 1 as probe
