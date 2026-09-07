-- The second cron loop: asking the generator whether it has finished.
--
-- 0007 wired one wake-up, for publishing. This adds the other one, and the two
-- are deliberately separate jobs rather than one tick doing both work items --
-- a minute spent downloading a 40MB video must not be a minute in which nothing
-- gets published.
--
-- Same design as the publisher, for the same reasons: durability is in
-- generation_jobs, not in the trigger; a lost wake-up costs sixty seconds; and
-- `last_fired_at` is the heartbeat that answers "is it running" without digging
-- through cron internals.

alter table private.scheduler_config
  add column if not exists poll_url text,
  add column if not exists poll_last_fired_at timestamptz;

create or replace function tick_generations()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare cfg private.scheduler_config;
begin
  select * into cfg from private.scheduler_config where id;

  if cfg is null or not cfg.enabled or cfg.poll_url is null then
    return;
  end if;

  -- net.http_post, not extensions.net_http_post. pg_net creates its own `net`
  -- schema whatever the `with schema` clause said, and getting this wrong in
  -- 0007 failed invisibly: cron.job reported active while erroring every
  -- minute, and only cron.job_run_details knew.
  perform net.http_post(
    url     := cfg.poll_url,
    body    := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'x-cron-secret', cfg.cron_secret
    ),
    timeout_milliseconds := 5000
  );

  update private.scheduler_config set poll_last_fired_at = now() where id;
end $$;

revoke execute on function tick_generations() from anon, authenticated, public;

-- Unschedule first so re-running this migration is not an error.
select cron.unschedule('poll-generations')
 where exists (select 1 from cron.job where jobname = 'poll-generations');

select cron.schedule('poll-generations', '* * * * *', 'select tick_generations()');

-- ------------------------------------------------------- deferred rendering

-- Queues the media for posts whose slot is close enough to be worth paying for.
--
-- Not at plan time. Generating thirty videos when a plan is approved spends
-- real money on content that may be discarded, and provider outputs expire in
-- about seven days, so days eight to thirty would rot before they published.
-- render_after is scheduled_for minus the brand's lead time, set by
-- activate_plan.
--
-- This only marks work as ready. What submits it is the same poll tick, so a
-- person is never waiting on a queue they cannot see.
create or replace function due_for_render(p_limit int default 10)
returns table (post_id uuid, user_id uuid, brand_id uuid, prompt text)
language sql
security definer
set search_path = public
as $$
  select p.id, p.user_id, p.brand_id,
         case when btrim(p.concept) <> '' then p.concept else p.hook end
    from posts p
    join brand_settings s on s.brand_id = p.brand_id
   where p.status = 'scheduled'
     and p.render_after is not null
     and p.render_after <= now()
     and p.media_strategy = 'generate'
     and s.is_on
     -- Nothing already being made, and nothing that already has a video.
     and not exists (
       select 1 from generation_jobs g
        where g.post_id = p.id
          and g.status in ('queued','submitted','running','succeeded')
     )
   order by p.scheduled_for
   limit p_limit;
$$;

revoke execute on function due_for_render(int) from anon, authenticated, public;
