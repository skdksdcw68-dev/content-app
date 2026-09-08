-- One correction to 0019: show the most recent failure, not the alphabetical one.
--
-- The detail line came from `max(p.failure_reason)`, and max() on text sorts
-- alphabetically. An account carrying both a stale "model_not_found" and the
-- real, current failure would be told about whichever word happened to sort
-- higher. The entire value of this banner is that the sentence under it is true
-- right now, so it takes the reason from the latest failed post and nothing else.

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
    select count(*) as total
      from posts p
      join mine m on m.id = p.brand_id
     where p.status = 'failed'
       and p.updated_at > now() - interval '7 days'
  ),
  latest_reason as (
    select p.failure_reason as reason
      from posts p
      join mine m on m.id = p.brand_id
     where p.status = 'failed'
       and p.updated_at > now() - interval '7 days'
     order by p.updated_at desc
     limit 1
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
           coalesce((select reason from latest_reason),
                    'Something in the chain is refusing. Open the failed day to see what it said.')
     where (select yes from barren)

    union all
    select 'blocked', 'generation_failing',
           (select total from failures) || ' day' ||
             case when (select total from failures) = 1 then '' else 's' end ||
             ' failed in the last week',
           coalesce((select reason from latest_reason), 'Open one to see why.')
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
