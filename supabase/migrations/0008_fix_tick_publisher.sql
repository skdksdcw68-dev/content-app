-- Fixes the scheduler's wake-up call.
--
-- 0007 called `extensions.net_http_post`, which does not exist. pg_net creates
-- its own `net` schema regardless of the `with schema` clause on CREATE
-- EXTENSION, and the function is `net.http_post`.
--
-- The failure was invisible from the outside: cron.job ran every minute and
-- reported `failed` into cron.job_run_details, while the app showed nothing at
-- all -- a scheduler that looks installed and never fires. That is the argument
-- for `last_fired_at`: a heartbeat the row itself carries, so "is it actually
-- running" is one query rather than a dig through cron internals.

create or replace function tick_publisher()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg private.scheduler_config;
begin
  select * into cfg from private.scheduler_config where id;

  if cfg is null or not cfg.enabled then
    return;
  end if;

  perform net.http_post(
    url     := cfg.function_url,
    body    := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'x-cron-secret', cfg.cron_secret
    ),
    timeout_milliseconds := 5000
  );

  update private.scheduler_config set last_fired_at = now() where id;
end $$;

revoke execute on function tick_publisher() from anon, authenticated, public;
