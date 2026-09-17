-- 0044: a slot held by a dead post is free.
--
-- Posts left in an archived plan that never got a video or an approval were
-- still "taking" their slots, so a new upload for Remi Snap landed a week out
-- behind six drafts nobody will make. Only live posts hold a slot now.

create or replace function allocate_slots(
  p_brand_id      uuid,
  p_starts_on     date,
  p_days          int,
  p_posts_per_day int
) returns table (slot_at timestamptz, pillar_id uuid, day_index int, slot_index int)
language plpgsql set search_path = public as $$
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
  v_last_used  int[];
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
    v_assigned  := array_fill(0,  array[array_length(v_pillars, 1)]);
    -- -1 means never used, so an untouched theme wins any tie against one that
    -- has already had a turn.
    v_last_used := array_fill(-1, array[array_length(v_pillars, 1)]);
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
           and not (
             p.status in ('planned', 'scripted', 'scheduled')
             and exists (select 1 from content_plans pl where pl.id = p.plan_id and pl.status = 'archived')
             and not exists (select 1 from post_targets t where t.post_id = p.id and t.consent_id is not null)
           )
      );

      if array_length(v_pillars, 1) is null then
        pillar_id := null;
      else
        -- Largest shortfall against the theme's fair share so far. Over a month
        -- this converges on the declared weights instead of merely cycling
        -- through them.
        v_best := 1;
        v_best_score := null;
        for v_k in 1 .. array_length(v_pillars, 1) loop
          v_score := (v_weights[v_k]::numeric / v_total_w) * (v_placed + 1) - v_assigned[v_k];

          if v_best_score is null
             or v_score > v_best_score
             -- The tie-break. Equal shortfall goes to whichever theme has waited
             -- longest, which is deterministic and keeps themes from clumping.
             or (v_score = v_best_score and v_last_used[v_k] < v_last_used[v_best])
          then
            v_best_score := v_score;
            v_best := v_k;
          end if;
        end loop;

        pillar_id := v_pillars[v_best];
        v_assigned[v_best]  := v_assigned[v_best] + 1;
        v_last_used[v_best] := v_placed;
      end if;

      slot_at    := v_slot;
      day_index  := v_day;
      slot_index := v_i;
      v_placed   := v_placed + 1;
      return next;
    end loop;
  end loop;
end $$;

revoke execute on function allocate_slots(uuid, date, int, int) from anon, authenticated;
