-- Two corrections to 0018, both found by running it.
--
-- 1. It could not be checked. Everything hung off `auth.uid()`, which is null
--    under the service role, so a worker or an operator asking "is this person
--    stuck" got an empty answer that looked like health. A monitor nobody can
--    run against another account is not a monitor. The body moves into a
--    function that takes the user, and the client-facing one passes its own.
--
-- 2. `no_connection` fired for somebody with no brands at all. Every other
--    check counts rows joined to their brands, so an empty account produced
--    zero connections and the warning was true in the same way that it is true
--    of a stranger. Someone who has not started is not stuck.

create or replace function autopilot_health_for(p_user uuid)
returns table (
  severity text,
  code     text,
  title    text,
  detail   text
)
language sql
security definer
set search_path = public
as $$
  with mine as (
    select b.id, b.name, s.is_on
      from brands b
      join brand_settings s on s.brand_id = b.id
     where b.user_id = p_user
       and b.archived_at is null
  ),
  generator as (
    select count(*) filter (where revoked_at is null and octet_length(secret_ct) > 0) as total,
           count(*) filter (where revoked_at is null and last_probe_ok is false)      as failing
      from private.provider_credentials
     where user_id = p_user
  ),
  connected as (
    select count(*) as total
      from platform_connections c
      join mine m on m.id = c.brand_id
     where c.status = 'active'
  ),
  produced as (
    select count(*) as total
      from media_assets a
      join mine m on m.id = a.brand_id
  ),
  failures as (
    select count(*) as total, max(p.failure_reason) as reason
      from posts p
      join mine m on m.id = p.brand_id
     where p.status = 'failed'
       and p.updated_at > now() - interval '7 days'
  ),
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
  barren as (
    select exists (
      select 1
        from posts p
        join mine m on m.id = p.brand_id
       where m.is_on
         and p.render_after is not null
         and p.render_after < now() - interval '24 hours'
    ) and (select total from produced) = 0 as yes
  ),
  -- Nothing below is said to somebody who has not set anything up yet.
  started as (select count(*) > 0 as yes from mine)

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
     where (select yes from started) and (select total from connected) = 0
  ) as findings(severity, code, title, detail)
  order by case severity when 'blocked' then 0 else 1 end;
$$;

revoke execute on function autopilot_health_for(uuid) from anon, authenticated, public;

-- What the app calls, about itself and nobody else.
create or replace function autopilot_health()
returns table (
  severity text,
  code     text,
  title    text,
  detail   text
)
language sql
security definer
set search_path = public
as $$
  select * from autopilot_health_for((select auth.uid()));
$$;

revoke execute on function autopilot_health() from anon, public;
grant  execute on function autopilot_health() to authenticated;
