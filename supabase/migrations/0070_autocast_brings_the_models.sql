-- Nobody is asked to connect a generator any more.
--
-- Abel, 25 Sep 2026: "instead of asking users to connect with connector who
-- even doesnt knows thats that then what if we make our own? So they just
-- choose a model we have."
--
-- 0068 made that true underneath: there is a house generator and everybody
-- can reach it. What it did not do is stop the PRODUCT talking about
-- connectors. The big card on Home still read "Connect a generator once", the
-- Create page offered it, the plus menu said "Connect a generator first", and
-- this function still told people their generator needed reconnecting -- all
-- of it decided from `private.provider_credentials`, which only ever counts a
-- person's OWN keys and is empty for everyone using the house account.
--
-- So the app would have gone on demanding a connector from people who could
-- already generate. That is worse than before it worked.
--
-- One question, asked in one place: can this person make a video right now?

create or replace function can_generate(p_user uuid default null, p_capability text default 'video_generation')
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
      from connection_models m
      join connections c on c.id = m.connection_id
     where m.capability = p_capability
       and m.available
       and c.status = 'active'
       and c.revoked_at is null
       and (c.user_id = coalesce(p_user, (select auth.uid())) or c.is_house)
  );
$$;

grant execute on function can_generate(uuid, text) to authenticated;

comment on function can_generate(uuid, text) is
  'Whether this person can generate at all -- their own connection or the house one. The app asks this instead of counting their keys, so nobody is told to connect something they do not need.';

-- And the health report stops raising a generator problem the house account
-- already solves. `provider_credentials` counts only somebody's own keys; a
-- person on the house generator has none and is not broken.
create or replace function autopilot_health_for(p_user uuid)
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
  with mine as (
    select b.id, s.is_on
      from brands b
      join brand_settings s on s.brand_id = b.id
     where b.user_id = p_user
       and b.archived_at is null
  ),
  -- The one change that matters: their own keys, OR the house generator.
  covered as (
    select can_generate(p_user, 'video_generation') as ok
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
  held as (
    select count(*) as total
      from posts p
      join mine m on m.id = p.brand_id
     where p.status in ('planned', 'scheduled')
  ),
  held_phrase as (
    select case
             when (select total from held) = 0 then 'nothing is waiting'
             when (select total from held) = 1 then '1 scheduled post is waiting'
             else (select total from held)::text || ' scheduled posts are waiting'
           end as text
  ),
  cause as (
    select j.failure_code as code
      from generation_jobs j
      join mine m on m.id = j.brand_id
     where j.status = 'failed'
     order by j.created_at desc
     limit 1
  )
  select * from (
    select 'blocked'::text, 'no_credits'::text,
           'Your generation credits are unavailable'::text,
           ('Autopilot paused video creation until more credits are available, so '
             || (select text from held_phrase) || '.')::text,
           'Manage credits'::text, 'generator'::text
     where (select code from cause) = 'no_credits'

    union all
    -- Only when they are on their OWN generator and it is broken. Somebody on
    -- the house account is never told to go and reconnect something.
    select 'blocked', 'generator_unavailable',
           'Video generation is unavailable',
           'Your generator needs reconnecting, so ' || (select text from held_phrase) || '.',
           'Fix generator', 'generator'
     where not (select ok from covered)
       and ((select failing from generator) > 0
            or (select code from cause) in ('bad_key', 'no_models'))

    union all
    select 'blocked', 'no_generator',
           'Autopilot needs attention',
           'Video generation is not set up yet, so ' || (select text from held_phrase) || '.',
           'Add a generator', 'generator'
     where exists (select 1 from mine where is_on)
       and not (select ok from covered)

    union all
    select 'blocked', 'connection_expired',
           'Publishing needs attention',
           'No account is connected to post to, so ' || (select text from held_phrase) || '.',
           'Connect an account', 'connections'
     where (select active from connections) = 0

    union all
    select 'info', 'nothing_planned',
           'Nothing is planned',
           'Autopilot is on and there is nothing scheduled to post.',
           'Plan a month', 'plan'
     where exists (select 1 from mine where is_on)
       and (select total from held) = 0
       and (select ok from covered)
       and (select active from connections) > 0
  ) as findings;
$$;
