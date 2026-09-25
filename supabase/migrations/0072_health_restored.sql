-- Restores every clause 0070 dropped.
--
-- 🔴 MY MISTAKE, CAUGHT BY COUNTING. 0070 needed two `where` clauses changed
-- so that somebody on the house generator is not told to go and connect one.
-- I rewrote the whole function from memory to make that change, and a rewrite
-- of a 130-line function silently lost things: the TikTok reconnect finding,
-- the catch-all that reports a failure whose code nobody recognised, the
-- `waiting` and `started` terms they are built on, and the `limit 1` that
-- makes this return ONE finding rather than a list.
--
-- Losing the limit is the loud one: the You page would have shown every
-- finding at once instead of the worst. Losing the catch-all is the quiet
-- one, and quiet is worse -- a failure with an unfamiliar code would have
-- stopped being reported at all, which is the exact fault this function was
-- written for in September.
--
-- This is 0021 verbatim with the two conditions patched in place and nothing
-- else touched, checked by counting clauses before it was applied: 5 union
-- alls, 2 limits, 3 references to `covered`.

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
  -- Their own generator, OR the house one (0068). The old checks counted
  -- only somebody's own keys, so everybody on the house generator looked
  -- broken and was told to connect something they did not need.
  covered as (
    select can_generate(p_user, 'video_generation') as ok
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
     where not (select ok from covered)
       and ((select failing from generator) > 0
            or (select code from cause) in ('bad_key','no_models'))

    union all
    select 'blocked', 'no_generator',
           'Autopilot needs attention',
           'Video generation is not set up yet, so ' || (select text from held_phrase) || '.',
           'Add a generator', 'generator'
     where exists (select 1 from mine where is_on) and not (select ok from covered)

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
       and (select ok from covered)

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
