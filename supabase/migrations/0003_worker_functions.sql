-- Worker plumbing: claiming work, releasing it when a worker dies, spending
-- quota, and laying out a schedule.
--
-- Everything here runs as the service role. None of it is reachable from a
-- client -- the grants at the bottom revoke execute from anon and authenticated,
-- because `consume_quota` deciding you have credit is not a decision a phone
-- should get to make.

-- ------------------------------------------------------------ quiet hours

-- Ported from AutopilotSettings.isQuiet(hour:) in the Swift app, which is the
-- one piece of that codebase that was unambiguously correct. The wrapping case
-- (start > end, e.g. 22:00 to 07:00) is the normal one and the easy one to get
-- wrong; start == end means no quiet window at all, not a 24-hour one.
create or replace function is_quiet_hour(p_hour int, p_start int, p_end int)
returns boolean
language sql immutable parallel safe as $$
  select case
    when p_start = p_end  then false
    when p_start < p_end  then p_hour >= p_start and p_hour < p_end
    else                       p_hour >= p_start or  p_hour < p_end
  end;
$$;

-- ---------------------------------------------------------- slot allocation

-- Lays out where posts go, and which pillar each one comes from.
--
-- Two pieces of prior art fused into one function:
--   * the app's plannableSlots(days:from:) -- spread across the day, skip quiet
--     hours, skip the past, never double-book a slot
--   * the old planner's weighted-shortfall pillar selection -- which the app
--     never actually implemented (it went round-robin and silently ignored
--     `weight`, so a pillar weighted 3 got the same share as one weighted 1)
--
-- Deliberately arithmetic rather than model output. A model asked to lay out 30
-- timestamps in a timezone with a wrapping quiet window will get it wrong, and
-- charge for the privilege.
create or replace function allocate_slots(
  p_brand_id      uuid,
  p_starts_on     date,
  p_days          int,
  p_posts_per_day int
) returns table (slot_at timestamptz, pillar_id uuid, day_index int, slot_index int)
language plpgsql as $$
declare
  v_tz         text;
  v_qs         smallint;
  v_qe         smallint;
  -- Spread across the day rather than clustering: a person scrolls at different
  -- hours, and three posts at 09:00 waste two of them.
  v_hours      int[] := array[9, 12, 15, 18, 20];
  v_candidates int[] := '{}';
  v_h          int;
  v_day        int;
  v_i          int;
  v_slot       timestamptz;
  v_pillars    uuid[];
  v_weights    int[];
  v_assigned   int[];
  v_total_w    int := 0;
  v_placed     int := 0;
  v_k          int;
  v_best       int;
  v_best_score numeric;
  v_score      numeric;
begin
  select b.timezone, s.quiet_hours_start, s.quiet_hours_end
    into v_tz, v_qs, v_qe
    from brands b
    join brand_settings s on s.brand_id = b.id
   where b.id = p_brand_id;

  if v_tz is null then
    raise exception 'brand % has no settings row', p_brand_id;
  end if;

  foreach v_h in array v_hours loop
    if not is_quiet_hour(v_h, v_qs, v_qe) then
      v_candidates := v_candidates || v_h;
    end if;
  end loop;

  -- Quiet hours covering every candidate hour is a real configuration, and it
  -- means there is nowhere legal to post. Say so rather than returning nothing
  -- and letting the caller conclude the plan is empty for some other reason.
  if array_length(v_candidates, 1) is null then
    raise exception 'quiet hours (% to %) cover every candidate slot', v_qs, v_qe
      using errcode = 'check_violation';
  end if;

  select coalesce(array_agg(id     order by created_at, id), '{}'),
         coalesce(array_agg(weight order by created_at, id), '{}')
    into v_pillars, v_weights
    from content_pillars
   where brand_id = p_brand_id and is_enabled;

  if array_length(v_pillars, 1) is not null then
    v_assigned := array_fill(0, array[array_length(v_pillars, 1)]);
    select sum(w) into v_total_w from unnest(v_weights) w;
  end if;

  for v_day in 0 .. p_days - 1 loop
    for v_i in 0 .. p_posts_per_day - 1 loop
      v_h := v_candidates[(v_i % array_length(v_candidates, 1)) + 1];

      -- Built in the brand's own timezone. 0001 evaluated this in UTC on the
      -- server and device-local in the app, so the same setting produced two
      -- different schedules depending on who was asking.
      v_slot := ((p_starts_on + v_day) + make_time(v_h, 0, 0)) at time zone v_tz;

      continue when v_slot <= now();

      continue when exists (
        select 1 from posts p
         where p.brand_id = p_brand_id
           and p.scheduled_for = v_slot
           and p.status <> 'failed'
      );

      if array_length(v_pillars, 1) is null then
        pillar_id := null;
      else
        -- Largest shortfall against the pillar's fair share so far. Over a
        -- month this converges on the declared weights instead of merely
        -- cycling through them.
        v_best := 1;
        v_best_score := null;
        for v_k in 1 .. array_length(v_pillars, 1) loop
          v_score := (v_weights[v_k]::numeric / v_total_w) * (v_placed + 1) - v_assigned[v_k];
          if v_best_score is null or v_score > v_best_score then
            v_best_score := v_score;
            v_best := v_k;
          end if;
        end loop;
        pillar_id := v_pillars[v_best];
        v_assigned[v_best] := v_assigned[v_best] + 1;
      end if;

      slot_at    := v_slot;
      day_index  := v_day;
      slot_index := v_i;
      v_placed   := v_placed + 1;
      return next;
    end loop;
  end loop;
end $$;

-- ------------------------------------------------------------------ quota

-- Spent BEFORE work is enqueued, never after. A job that runs and then discovers
-- it was over budget has already cost the money.
create or replace function consume_quota(p_user uuid, p_kind text, p_units int)
returns boolean
language plpgsql as $$
declare
  v_period date := date_trunc('month', now())::date;
  v_limit  int;
  v_ok     boolean;
begin
  select case p_kind
           when 'image_gen' then c.monthly_image_gens
           when 'video_gen' then c.monthly_video_gens
           when 'llm_cents' then c.monthly_llm_cents
           else 0
         end
    into v_limit
    from plans_catalog c
    left join subscriptions s
      on s.plan_code = c.code and s.user_id = p_user and s.status in ('active','grace')
   where c.code = coalesce(
           (select plan_code from subscriptions
             where user_id = p_user and status in ('active','grace')),
           'free')
   limit 1;

  if v_limit is null then
    return false;
  end if;

  insert into quota_counters (user_id, period_start, kind, used, limit_value)
  values (p_user, v_period, p_kind, 0, v_limit)
  on conflict (user_id, period_start, kind)
    -- Re-assert the limit each time: a plan upgrade mid-month must take effect
    -- immediately, and a downgrade must not leave a stale ceiling behind.
    do update set limit_value = excluded.limit_value;

  update quota_counters
     set used = used + p_units
   where user_id = p_user
     and period_start = v_period
     and kind = p_kind
     and used + p_units <= limit_value
  returning true into v_ok;

  return coalesce(v_ok, false);
end $$;

-- ------------------------------------------------------------- claiming

-- Publishing is the only claim with a rate limit, and the limit is applied
-- INSIDE the claim rather than checked beforehand. Checking first and acting
-- second is how two workers both decide they are under the cap.
--
-- Written as a loop rather than one clever CTE because the per-connection gate
-- has to be evaluated and consumed per row. At a handful of posts a minute the
-- performance difference is nil and the correctness difference is total.
create or replace function claim_publish_jobs(
  p_worker text,
  p_batch  int      default 5,
  p_lease  interval default '10 minutes'
) returns setof publish_jobs
language plpgsql as $$
declare
  v_job   publish_jobs;
  v_taken int := 0;
begin
  for v_job in
    select j.*
      from publish_jobs j
     where j.state = 'pending'
       and j.run_at <= now()
       and j.expires_at > now()
     order by j.run_at
     limit greatest(p_batch * 4, 20)
     for update of j skip locked
  loop
    exit when v_taken >= p_batch;

    update account_rate_state r
       set minute_window = greatest(r.minute_window, date_trunc('minute', now())),
           minute_count  = case when r.minute_window < date_trunc('minute', now())
                                then 1 else r.minute_count + 1 end,
           day_window    = greatest(r.day_window, current_date),
           day_count     = case when r.day_window < current_date
                                then 1 else r.day_count + 1 end
     where r.connection_id = v_job.connection_id
       and coalesce(r.cooldown_until, '-infinity') < now()
       and (r.minute_window < date_trunc('minute', now()) or r.minute_count < r.max_per_minute)
       and (r.day_window    < current_date               or r.day_count    < r.max_per_day);

    -- Over the cap, cooling down, or no rate row at all: leave it pending and
    -- let the next tick try again.
    continue when not found;

    update publish_jobs
       set state       = 'claimed',
           claimed_by  = p_worker,
           lease_until = now() + p_lease,
           attempts    = attempts + 1
     where id = v_job.id
    returning * into v_job;

    v_taken := v_taken + 1;
    return next v_job;
  end loop;
end $$;

create or replace function claim_generation_jobs(
  p_worker text,
  p_batch  int      default 5,
  p_lease  interval default '15 minutes'
) returns setof generation_jobs
language plpgsql as $$
begin
  return query
  with candidate as (
    select j.id
      from generation_jobs j
     where j.status = 'queued'
       and j.run_at <= now()
       and j.attempts < j.max_attempts
     order by j.run_at
     limit p_batch
     for update of j skip locked
  )
  update generation_jobs g
     set status      = 'running',
         claimed_by  = p_worker,
         lease_until = now() + p_lease,
         attempts    = g.attempts + 1
   where g.id in (select id from candidate)
  returning g.*;
end $$;

-- Jobs whose provider says nothing and whose webhook never arrived. The webhook
-- is an optimisation; this is the path that actually guarantees completion.
create or replace function claim_pollable_jobs(
  p_worker text,
  p_batch  int      default 20,
  p_lease  interval default '2 minutes'
) returns setof generation_jobs
language plpgsql as $$
begin
  return query
  with candidate as (
    select j.id
      from generation_jobs j
     where j.status in ('submitted','running')
       and j.poll_after is not null
       and j.poll_after <= now()
     order by j.poll_after
     limit p_batch
     for update of j skip locked
  )
  update generation_jobs g
     set claimed_by  = p_worker,
         lease_until = now() + p_lease,
         poll_after  = null
   where g.id in (select id from candidate)
  returning g.*;
end $$;

create or replace function claim_agent_runs(
  p_worker text,
  p_batch  int      default 2,
  p_lease  interval default '10 minutes'
) returns setof agent_runs
language plpgsql as $$
begin
  return query
  with candidate as (
    select r.id
      from agent_runs r
     where r.status = 'queued'
     order by r.created_at
     limit p_batch
     for update of r skip locked
  )
  update agent_runs a
     set status      = 'running',
         claimed_by  = p_worker,
         claimed_at  = now(),
         lease_until = now() + p_lease,
         attempts    = a.attempts + 1
   where a.id in (select id from candidate)
  returning a.*;
end $$;

-- --------------------------------------------------------------- recovery

-- A worker that dies mid-job holds its lease until it expires. This is what
-- turns "the container was OOM-killed" into "the job ran ninety seconds late"
-- rather than "the post never went out and nothing said so".
create or replace function reap_leases()
returns table (kind text, reaped int)
language plpgsql as $$
declare
  v_runs int; v_gen int; v_pub int;
begin
  update agent_runs
     set status = case when attempts >= 3 then 'failed'::agent_run_status else 'queued' end,
         claimed_by = null, lease_until = null,
         error = case when attempts >= 3 then 'worker lease expired 3 times' else error end,
         finished_at = case when attempts >= 3 then now() else null end
   where status = 'running' and lease_until < now();
  get diagnostics v_runs = row_count;

  update generation_jobs
     set status = case when attempts >= max_attempts then 'failed'::job_status else 'queued' end,
         claimed_by = null, lease_until = null,
         error = case when attempts >= max_attempts then 'worker lease expired' else error end,
         finished_at = case when attempts >= max_attempts then now() else null end
   where status = 'running' and lease_until < now();
  get diagnostics v_gen = row_count;

  update publish_jobs
     set state = case when attempts >= max_attempts then 'failed'::publish_state else 'pending' end,
         claimed_by = null, lease_until = null,
         last_error = case when attempts >= max_attempts then 'worker lease expired' else last_error end
   where state in ('claimed','uploading') and lease_until < now();
  get diagnostics v_pub = row_count;

  return query values ('agent_runs', v_runs), ('generation_jobs', v_gen), ('publish_jobs', v_pub);
end $$;

-- A post that missed its window does NOT go out late. After an outage, firing
-- a day of backlog in ten minutes is worse for the account than posting nothing,
-- and it will trip the platform's own spam heuristics on the way.
create or replace function expire_publish_jobs()
returns int
language plpgsql as $$
declare v_n int;
begin
  with expired as (
    update publish_jobs
       set state = 'failed', last_error = 'missed_window'
     where state = 'pending' and expires_at <= now()
    returning post_target_id
  )
  update post_targets t
     set state = 'failed',
         failure_code = 'missed_window',
         failure_reason = 'The scheduled time passed while the publisher was unavailable. It was not posted late on purpose.'
    from expired e
   where t.id = e.post_target_id;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ------------------------------------------------------------------ grants

-- None of this is client-reachable. `consume_quota` in particular must never be
-- callable by the thing whose quota it is.
revoke execute on function claim_publish_jobs(text, int, interval)     from anon, authenticated;
revoke execute on function claim_generation_jobs(text, int, interval)  from anon, authenticated;
revoke execute on function claim_pollable_jobs(text, int, interval)    from anon, authenticated;
revoke execute on function claim_agent_runs(text, int, interval)       from anon, authenticated;
revoke execute on function consume_quota(uuid, text, int)              from anon, authenticated;
revoke execute on function allocate_slots(uuid, date, int, int)        from anon, authenticated;
revoke execute on function reap_leases()                               from anon, authenticated;
revoke execute on function expire_publish_jobs()                       from anon, authenticated;
