-- A day has five posting hours. One post a day only ever tried the first.
--
-- Abel, 25 Sep 2026, starting a series at 10:45: "That didn't start -- every
-- slot in that range is already taken or in the past."
--
-- He was not wrong and neither was the message. A series asks for ONE post on
-- ONE day, so `allocate_slots` ran with p_days = 1 and p_posts_per_day = 1,
-- and the hour it picked was:
--
--     v_h := v_candidates[(v_i % array_length(v_candidates, 1)) + 1];
--
-- With v_i always 0, that is always `v_candidates[1]` -- 09:00. Past 9am the
-- slot is behind `now()`, `continue` skips it, the loop ends with nothing, and
-- the caller correctly reports that there is nowhere to put it. 12:00, 15:00,
-- 18:00 and 20:00 were sitting there unconsidered.
--
-- So: starting a series worked before 9am and at no other time of day. The
-- same fault quietly wasted the first day of every month plan begun after
-- breakfast -- 29 days instead of 30, reported as "dropped" and blamed on the
-- writer.
--
-- The fix is to treat the hour as a starting point rather than the only
-- answer. Each post walks the day's remaining hours in order and takes the
-- first that is in the future and unclaimed. Where the old code found a slot,
-- this finds the same one: the walk begins exactly where the old expression
-- pointed, so a full day still lays out 9, 12, 15, 18, 20 in that order.
--
-- `v_used` stops two posts on the same day landing on the same hour. The
-- existing `exists` check cannot do it: the rows this call returns are not in
-- `posts` until the caller writes them.
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
  v_count      int;
  v_h          int;
  v_day        int;
  v_i          int;
  v_try        int;
  v_found      boolean;
  v_used       int[];
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
  v_count := array_length(v_candidates, 1);

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
    v_used := '{}';

    for v_i in 0 .. p_posts_per_day - 1 loop
      -- Every hour left in the day, starting where this post's turn falls.
      v_found := false;
      for v_try in 0 .. v_count - 1 loop
        v_h := v_candidates[((v_i + v_try) % v_count) + 1];
        continue when v_h = any(v_used);

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

        v_found := true;
        exit;
      end loop;

      -- Nothing left today. The next day gets its own five chances.
      continue when not v_found;
      v_used := v_used || v_h;

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

alter function allocate_slots(uuid, date, int, int) set search_path = public;
revoke execute on function allocate_slots(uuid, date, int, int) from anon, authenticated;
