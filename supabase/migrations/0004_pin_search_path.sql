-- Pin search_path on every function.
--
-- Supabase's own linter flags all twelve as `function_search_path_mutable`, and
-- it is right to. A function without a fixed search_path resolves unqualified
-- names against whatever the caller's path happens to be, so anyone able to
-- create an object in a schema earlier in that path can shadow a table or an
-- operator and have our code call theirs instead. `consume_quota` deciding
-- against an attacker's `quota_counters` is the version of that bug that costs
-- actual money.
--
-- Everything these functions touch lives in public, and pg_catalog is searched
-- first implicitly, so pinning to public is enough. pg_temp is deliberately not
-- in the list: a temp schema early in the path is the exact hijack this is
-- guarding against.

alter function is_quiet_hour(int, int, int)                set search_path = public;
alter function allocate_slots(uuid, date, int, int)        set search_path = public;
alter function consume_quota(uuid, text, int)              set search_path = public;
alter function claim_publish_jobs(text, int, interval)     set search_path = public;
alter function claim_generation_jobs(text, int, interval)  set search_path = public;
alter function claim_pollable_jobs(text, int, interval)    set search_path = public;
alter function claim_agent_runs(text, int, interval)       set search_path = public;
alter function reap_leases()                               set search_path = public;
alter function expire_publish_jobs()                       set search_path = public;
alter function assert_brand_owner()                        set search_path = public;
alter function assert_publishable_asset()                  set search_path = public;
alter function touch_updated_at()                          set search_path = public;
