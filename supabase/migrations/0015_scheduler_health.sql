-- Is the scheduler actually running?
--
-- 0007's lesson was that cron.job says `active: true` while erroring every
-- minute, and only cron.job_run_details knows. The heartbeat columns already
-- answer it; this makes them readable without opening a SQL console, which is
-- the difference between checking and assuming.
--
-- No secrets: the URLs and the timestamps only. cron_secret stays where it is.
create or replace function scheduler_health()
returns table (
  publisher_last_fired timestamptz,
  poller_last_fired    timestamptz,
  enabled              boolean,
  publisher_url_set    boolean,
  poller_url_set       boolean
)
language sql
security definer
set search_path = public
as $$
  select last_fired_at, poll_last_fired_at, enabled,
         function_url is not null, poll_url is not null
    from private.scheduler_config where id;
$$;

revoke execute on function scheduler_health() from anon, authenticated, public;
