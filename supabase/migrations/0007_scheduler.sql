-- The thing that makes this an autopilot rather than a nicer publish button.
--
-- pg_cron wakes an Edge Function every minute; the function claims whatever is
-- due and publishes it. The app is not involved at any point, which is the
-- whole product.
--
-- pg_net is fire-and-forget, and that is fine HERE and would not be anywhere
-- else: the durability lives in publish_jobs, not in the trigger. A lost wake-up
-- means the next tick claims the same rows, because only a successful claim
-- moves a job out of `pending`.

create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

-- Where the scheduler finds its own configuration. One row, service-role only.
-- The secret is here rather than in the cron command because pg_cron job
-- definitions are readable by anyone who can see cron.job.
create table private.scheduler_config (
  id             boolean primary key default true check (id),
  function_url   text not null,
  cron_secret    text not null,
  enabled        boolean not null default true,
  last_fired_at  timestamptz,
  updated_at     timestamptz not null default now()
);

-- Fires the runner. Returns quickly; the request completes on its own.
create or replace function tick_publisher()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare cfg private.scheduler_config;
begin
  select * into cfg from private.scheduler_config where id;

  if cfg is null or not cfg.enabled then
    return;
  end if;

  perform extensions.net_http_post(
    url     := cfg.function_url,
    headers := jsonb_build_object(
      'Content-Type',   'application/json',
      'x-cron-secret',  cfg.cron_secret
    ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 5000
  );

  update private.scheduler_config set last_fired_at = now() where id;
end $$;

revoke execute on function tick_publisher() from anon, authenticated, public;

-- Every minute. A post scheduled for 09:00 goes out somewhere in 09:00-09:01,
-- which is closer than anybody watching a feed can tell.
select cron.schedule('publish-due-posts', '* * * * *', 'select tick_publisher()');

-- Nightly housekeeping that does not need to run on every tick.
select cron.schedule('reap-stale-leases', '*/5 * * * *', 'select reap_leases()');
select cron.schedule('expire-missed-windows', '*/5 * * * *', 'select expire_publish_jobs()');
select cron.schedule('purge-oauth-states', '17 * * * *', 'select purge_oauth_states()');

-- ------------------------------------------------------------------ scheduling

-- When a post should go out. Until now approval and publishing were the same
-- gesture; this is what separates them.
alter table post_targets
  add column if not exists scheduled_for timestamptz;

create index if not exists post_targets_due_idx
  on post_targets (scheduled_for)
  where state = 'pending' and scheduled_for is not null;

-- Puts an approved post in the queue for a specific time.
--
-- expires_at is the anti-thundering-herd guard: if the publisher is down for
-- four hours, the backlog is NOT fired on recovery. Those rows fail as
-- 'missed_window' and the person is told. Forty posts in ten minutes is worse
-- for an account than none, and it trips the platform's own spam heuristics on
-- the way.
create or replace function schedule_publish(
  p_post_target_id uuid,
  p_run_at timestamptz
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target post_targets;
  v_job_id uuid;
begin
  select * into v_target from post_targets where id = p_post_target_id;

  if v_target is null then
    raise exception 'no such post';
  end if;

  -- Ownership is checked HERE, explicitly, because security definer bypasses
  -- RLS. Without this line any signed-in person could schedule anybody else's
  -- post simply by knowing an id. The service role is exempt so the scheduler
  -- and the approval function can call it on a user's behalf.
  if auth.uid() is not null and v_target.user_id <> auth.uid() then
    raise exception 'that post is not yours';
  end if;

  if v_target.consent_id is null then
    raise exception 'that post has not been approved';
  end if;

  update post_targets set scheduled_for = p_run_at where id = p_post_target_id;

  insert into publish_jobs (user_id, post_target_id, connection_id, run_at, expires_at)
  values (
    v_target.user_id,
    v_target.id,
    v_target.connection_id,
    p_run_at,
    p_run_at + interval '90 minutes'
  )
  on conflict (post_target_id) do update
    set run_at     = excluded.run_at,
        expires_at = excluded.expires_at,
        state      = 'pending',
        attempts   = 0,
        claimed_by = null,
        lease_until = null,
        last_error = null
  returning id into v_job_id;

  return v_job_id;
end $$;

revoke execute on function schedule_publish(uuid, timestamptz) from anon, public;
-- The app calls this one directly, which is why the ownership check inside it
-- is explicit rather than left to RLS.
grant execute on function schedule_publish(uuid, timestamptz) to authenticated;
