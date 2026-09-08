-- Say what happened, not what the provider said.
--
-- The banner from 0018-0020 put this on a customer's home screen:
--
--   Higgsfield refused this on billing or permissions — check credits and
--   model access for your API key at cloud.higgsfield.ai. Higgsfield said:
--   "not_enough_credits" (Kling 2.1 Master, 403).
--
-- Every word of that is true and none of it belongs there. It names a supplier
-- the customer did not choose, quotes an error code, and cites an HTTP status.
-- It is a stack trace wearing a sentence, and it is on the first screen of the
-- app.
--
-- The fix is not to reword it. It is that the reason must never travel as
-- prose in the first place. Failures now carry a `failure_code` -- a small
-- closed set decided where the failure happens, next to the response that
-- caused it -- and this function maps that code to something a person can act
-- on. The provider's own words stay in `generation_jobs.error`, which is where
-- diagnostics belong and where nobody is trying to run a business.
--
-- Each finding also carries the action it wants, so the banner can offer one
-- button and mean it.

alter table posts            add column if not exists failure_code text;
alter table generation_jobs  add column if not exists failure_code text;

comment on column posts.failure_code is
  'Closed set: no_credits, bad_key, no_models, provider_down, refused, bad_output. Drives customer-facing copy; the provider''s own message stays in generation_jobs.error.';

-- Both go before either comes back: `create or replace` cannot widen the row
-- type of a `returns table` (42P13), and the wrapper depends on the other, so
-- the dependent one is dropped first.
drop function if exists autopilot_health();
drop function if exists autopilot_health_for(uuid);

create or replace function autopilot_health_for(p_user uuid)
returns table (
  severity text,   -- 'blocked' | 'warning'
  code     text,
  title    text,
  detail   text,
  action   text,   -- button label, null when there is nothing to press
  route    text    -- where that button goes
)
language sql
security definer
set search_path = public
as $$
  with mine as (
    select b.id, s.is_on
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
  connections as (
    select count(*) filter (where c.status = 'active')  as active,
           count(*)                                     as total
      from platform_connections c
      join mine m on m.id = c.brand_id
  ),
  produced as (
    select count(*) as total from media_assets a join mine m on m.id = a.brand_id
  ),
  -- Everything currently held up: days that failed, and days past their render
  -- time with nothing started. One number, because the customer does not care
  -- which queue a post is stuck in.
  waiting as (
    select
      (select count(*) from posts p join mine m on m.id = p.brand_id
        where p.status = 'failed' and p.updated_at > now() - interval '7 days')
      +
      (select count(*) from posts p join mine m on m.id = p.brand_id
        where m.is_on and p.status = 'scheduled' and p.media_strategy = 'generate'
          and p.render_after is not null and p.render_after < now() - interval '3 hours'
          and not exists (select 1 from generation_jobs g
                           where g.post_id = p.id
                             and g.status in ('queued','submitted','running','succeeded')))
      as total
  ),
  -- Why the most recent failure failed, as a code and never as text.
  cause as (
    select p.failure_code as code
      from posts p
      join mine m on m.id = p.brand_id
     where p.status = 'failed'
       and p.updated_at > now() - interval '7 days'
     order by p.updated_at desc
     limit 1
  ),
  started as (select count(*) > 0 as yes from mine),
  -- A post that has never been said in the singular reads as a bug.
  n as (select greatest((select total from waiting), 1) as held),
  held_phrase as (
    select case when (select held from n) = 1
                then '1 scheduled post is waiting'
                else (select held from n) || ' scheduled posts are waiting'
           end as text
  )

  select * from (
    -- Billing first among the generation faults: it is the one the customer
    -- can fix in a minute, and every other generation message would be a
    -- distraction while it is true.
    select 'blocked'::text, 'no_credits'::text,
           'Your generation credits are unavailable'::text,
           ('Autopilot paused video creation until more credits are available, so '
             || (select text from held_phrase) || '.')::text,
           'Manage credits'::text, 'generator'::text
     where (select code from cause) = 'no_credits'

    union all
    select 'blocked', 'generator_unavailable',
           'Video generation is unavailable',
           'Your generator needs reconnecting, so ' || (select text from held_phrase) || '.',
           'Fix generator', 'generator'
     where (select failing from generator) > 0
        or (select code from cause) in ('bad_key','no_models')

    union all
    select 'blocked', 'no_generator',
           'Autopilot needs attention',
           'Video generation is not set up yet, so ' || (select text from held_phrase) || '.',
           'Add a generator', 'generator'
     where exists (select 1 from mine where is_on) and (select total from generator) = 0

    union all
    select 'blocked', 'connection_expired',
           'Publishing needs attention',
           'Your TikTok connection needs to be renewed. Nothing will go out until it is.',
           'Reconnect', 'connections'
     where (select total from connections) > 0 and (select active from connections) = 0

    -- The catch-all, and deliberately last: something is failing and the code
    -- did not say what. Vague, but honest, and it still routes somewhere.
    union all
    select 'blocked', 'generation_failing',
           'Autopilot needs attention',
           (select text from held_phrase) || ' because content could not be produced.',
           'See the plan', 'plan'
     where (select total from waiting) > 0
       and coalesce((select code from cause), 'unknown')
             not in ('no_credits','bad_key','no_models')
       and (select failing from generator) = 0
       and (select total from generator) > 0

    union all
    select 'warning', 'no_connection',
           'No account is connected',
           'Autocast can make videos, but there is nowhere to post them yet.',
           'Connect TikTok', 'connections'
     where (select yes from started) and (select total from connections) = 0
  ) as findings(severity, code, title, detail, action, route)
  order by case severity when 'blocked' then 0 else 1 end
  limit 1;
$$;

revoke execute on function autopilot_health_for(uuid) from anon, authenticated, public;

create or replace function autopilot_health()
returns table (
  severity text,
  code     text,
  title    text,
  detail   text,
  action   text,
  route    text
)
language sql
security definer
set search_path = public
as $$
  select * from autopilot_health_for((select auth.uid()));
$$;

revoke execute on function autopilot_health() from anon, public;
grant  execute on function autopilot_health() to authenticated;
