-- Wakes the long-job executor every minute.
--
-- Third loop, same shape as the two that already run: pg_net posts to an Edge
-- Function carrying the shared secret from `private.scheduler_config`, and the
-- function claims work with a lease. The secret stays in that row rather than
-- in the cron command because `cron.job` is readable by anyone who can see the
-- schema, and a secret in a job definition is a secret in a view.
--
-- The URL is derived from the publisher's rather than written out, for the same
-- reason 0014 derives the poller's: it cannot drift from the row beside it, and
-- it stays correct if the project ref ever changes.

alter table private.scheduler_config add column if not exists agent_url text;

update private.scheduler_config
   set agent_url = replace(function_url, 'run-due-posts', 'run-agent-jobs')
 where function_url like '%run-due-posts%';

create or replace function tick_agent_runs()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare cfg record;
begin
  select * into cfg from private.scheduler_config where id;

  -- Nothing configured means nothing fires. Deliberate: a scheduler that starts
  -- calling the moment the function exists would fire against a half-deployed
  -- system, which is how the publisher first failed silently.
  if cfg is null or not cfg.enabled or cfg.agent_url is null then
    return;
  end if;

  perform net.http_post(
    url     := cfg.agent_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', cfg.cron_secret
    ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 60000
  );

  update private.scheduler_config set agent_last_fired_at = now() where id;
end $$;

alter table private.scheduler_config add column if not exists agent_last_fired_at timestamptz;

revoke execute on function tick_agent_runs() from anon, authenticated, public;

-- Unscheduled first: cron.schedule raises on a duplicate name, and a
-- migration that cannot be re-run is a migration that fails the first time it
-- is retried after an unrelated error further down the file.
select cron.unschedule('run-agent-jobs') where exists (
  select 1 from cron.job where jobname = 'run-agent-jobs');

select cron.schedule('run-agent-jobs', '* * * * *', $job$select tick_agent_runs()$job$);

-- Reported alongside the other two, so "is the machine turning" stays one
-- question with one answer.
--
-- Dropped before recreating: `create or replace` cannot widen the row type of
-- a `returns table` (42P13). Third time in this project.
drop function if exists scheduler_health();

create or replace function scheduler_health()
returns table (
  publisher_last_fired timestamptz,
  poller_last_fired    timestamptz,
  agent_last_fired     timestamptz,
  enabled              boolean,
  publisher_url_set    boolean,
  poller_url_set       boolean,
  agent_url_set        boolean
)
language sql
security definer
set search_path = public
as $$
  select last_fired_at, poll_last_fired_at, agent_last_fired_at, enabled,
         function_url is not null, poll_url is not null, agent_url is not null
    from private.scheduler_config where id;
$$;
