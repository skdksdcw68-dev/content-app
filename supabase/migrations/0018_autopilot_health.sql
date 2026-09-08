-- Noticing that nothing is happening.
--
-- `scheduler_health()` in 0015 answers "are the cron loops firing", and for
-- three days in September it answered yes, every minute, correctly, while the
-- product produced absolutely nothing. Generation was refusing every request,
-- four publish jobs cancelled themselves for want of media, and the heartbeat
-- stayed green throughout, because a heartbeat measures the machine turning
-- rather than anything coming out of it.
--
-- That is the wrong question. This asks the right one: given what this person
-- switched on, is it working? Every check below is a thing that has actually
-- gone wrong, not a thing that might.
--
-- Deliberately about outcomes and never about steps. "The poller ran" is not
-- evidence of anything. "Autopilot has been on for two days and has never
-- produced a file" is the sentence somebody needed to read on Sunday.

create or replace function autopilot_health()
returns table (
  severity text,   -- 'blocked' | 'warning'
  code     text,   -- stable, for the app to switch on
  title    text,   -- one line, already readable
  detail   text    -- what to do about it
)
language sql
security definer
set search_path = public
as $$
  with me as (select (select auth.uid()) as uid),
  mine as (
    select b.id, b.name, s.is_on
      from brands b
      join brand_settings s on s.brand_id = b.id
     where b.user_id = (select uid from me)
       and b.archived_at is null
  ),
  -- The generator, if there is one. Read through a count rather than the
  -- credential itself: this function returns text to a client and must never
  -- be a route to anything sealed.
  generator as (
    select count(*) filter (where revoked_at is null and octet_length(secret_ct) > 0) as total,
           count(*) filter (where revoked_at is null and last_probe_ok is false)      as failing
      from private.provider_credentials
     where user_id = (select uid from me)
  ),
  connected as (
    select count(*) as total
      from platform_connections c
      join mine m on m.id = c.brand_id
     where c.status = 'active'
  ),
  -- What has actually come out, ever.
  produced as (
    select count(*) as total
      from media_assets a
      join mine m on m.id = a.brand_id
  ),
  -- Days that died, recently enough to still matter.
  failures as (
    select count(*) as total, max(p.failure_reason) as reason
      from posts p
      join mine m on m.id = p.brand_id
     where p.status = 'failed'
       and p.updated_at > now() - interval '7 days'
  ),
  -- Due for a video, well past the moment, and nothing was ever started for
  -- them. This is the shape of a queue that has quietly stopped being drained.
  stalled as (
    select count(*) as total
      from posts p
      join mine m on m.id = p.brand_id
     where m.is_on
       and p.status = 'scheduled'
       and p.media_strategy = 'generate'
       and p.render_after is not null
       and p.render_after < now() - interval '3 hours'
       and not exists (
         select 1 from generation_jobs g
          where g.post_id = p.id
            and g.status in ('queued','submitted','running','succeeded')
       )
  ),
  -- Autopilot has been on long enough to have produced something, and has not.
  -- The single check that would have caught September on its own.
  barren as (
    select exists (
      select 1
        from posts p
        join mine m on m.id = p.brand_id
       where m.is_on
         and p.render_after is not null
         and p.render_after < now() - interval '24 hours'
    ) and (select total from produced) = 0 as yes
  )

  select * from (
    select 'blocked'::text, 'no_generator'::text,
           'Autopilot is on, but no generator is connected'::text,
           'Nothing can be made until you add a Higgsfield key under You → Generators.'::text
     where exists (select 1 from mine where is_on) and (select total from generator) = 0

    union all
    select 'blocked', 'generator_failing',
           'Your generator key stopped working',
           'Reconnect it under You → Generators. Until then every video will fail.'
     where (select failing from generator) > 0

    union all
    select 'blocked', 'nothing_made',
           'Autopilot has been on for a day and has never made anything',
           'Something in the chain is refusing. Open the failed day to see what it said.'
     where (select yes from barren)

    union all
    select 'blocked', 'generation_failing',
           (select total from failures) || ' day' ||
             case when (select total from failures) = 1 then '' else 's' end ||
             ' failed in the last week',
           coalesce((select reason from failures), 'Open one to see why.')
     where (select total from failures) > 0

    union all
    select 'warning', 'render_stalled',
           (select total from stalled) || ' scheduled post' ||
             case when (select total from stalled) = 1 then '' else 's' end ||
             ' should have started by now',
           'They are past their render time with nothing queued. The poller may not be reaching them.'
     where (select total from stalled) > 0

    union all
    select 'warning', 'no_connection',
           'No account is connected',
           'Videos can still be made, but there is nowhere to post them. Connect TikTok under You.'
     where (select total from connected) = 0
  ) as findings(severity, code, title, detail)
  -- Blocked before warning, so the app can show the first row and be right.
  order by case severity when 'blocked' then 0 else 1 end;
$$;

revoke execute on function autopilot_health() from anon, public;
grant  execute on function autopilot_health() to authenticated;

comment on function autopilot_health() is
  'What is actually wrong with this user''s autopilot, worst first. Outcome checks, not liveness -- see 0015 for the heartbeat that stayed green through a three-day outage.';
