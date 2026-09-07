-- Tells tick_generations() where to call.
--
-- Derived from the publisher's own URL rather than written out, so this stays
-- correct if the project ref ever changes and cannot drift from the row it sits
-- next to. The cron secret is already in that row; only the path differs.
--
-- Until this runs, tick_generations() returns immediately and the poller never
-- fires -- which is deliberate. A scheduler that starts calling an endpoint the
-- moment the function is created would fire against a half-deployed system.
update private.scheduler_config
   set poll_url = replace(function_url, 'run-due-posts', 'poll-generations')
 where function_url like '%run-due-posts%';
