-- Answers that go somewhere, and an approval that means something.
--
-- 0022 created `strategies` and the read side of it. Nothing ever wrote one, so
-- the clarify gate asked its two questions, the person tapped "Grow followers",
-- and the answer went into the transcript and nowhere else. The next turn knew
-- nothing about it. A gate that collects answers it then discards is worse than
-- no gate: it costs a round trip and teaches the person their input is noise.
--
-- The whole sequence this completes:
--
--   understand -> what does brand_knowledge already say
--   clarify    -> ask only what is missing        (0022 + route.ts)
--   confirm    -> write the answers down           (record_answers, here)
--   reason     -> draft a strategy from them       (agent-chat)
--   produce    -> only after approve_strategy      (approve_strategy, here)
--
-- Nothing expensive happens before the last step, which is the point. Thirty
-- days of generation against a misunderstood goal is the single costliest
-- mistake this product can make, and it is silent -- the output looks fine.

-- Writes what the person said into the draft strategy, making one if needed.
--
-- Upsert rather than insert: the questions may be answered over several turns,
-- and a second answer should refine the same draft rather than start a rival.
-- Only non-null arguments are applied, so answering one thing does not blank
-- the rest.
create or replace function record_answers(
  p_brand    uuid,
  p_thread   uuid default null,
  p_goal     text default null,
  p_appetite text default null,
  p_audience text default null,
  p_cadence  smallint default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  v_id   uuid;
begin
  select user_id into v_user from brands where id = p_brand;
  if v_user is null then
    raise exception 'no such brand' using errcode = 'P0002';
  end if;

  -- Callable by the person (through the app) and by the agent (service role,
  -- auth.uid() null). Nobody else gets to write somebody's strategy.
  if (select auth.uid()) is not null and (select auth.uid()) <> v_user then
    raise exception 'not yours' using errcode = '42501';
  end if;

  -- The live draft, if there is one. An approved strategy is never edited in
  -- place -- see supersede_strategy below for why changing one means replacing
  -- it, not mutating what somebody already agreed to.
  select id into v_id
    from strategies
   where brand_id = p_brand
     and superseded_at is null
     and approved_at is null
   order by created_at desc
   limit 1;

  if v_id is null then
    insert into strategies (user_id, brand_id, thread_id, goal, appetite, audience, cadence)
    values (
      v_user, p_brand, p_thread, p_goal, p_appetite,
      coalesce(p_audience, ''), p_cadence
    )
    returning id into v_id;
  else
    update strategies
       set goal      = coalesce(p_goal, goal),
           appetite  = coalesce(p_appetite, appetite),
           audience  = case
                         when btrim(coalesce(p_audience, '')) <> '' then p_audience
                         else audience
                       end,
           cadence   = coalesce(p_cadence, cadence),
           thread_id = coalesce(p_thread, thread_id)
     where id = v_id;
  end if;

  return v_id;
end $$;

-- The agent's reasoning, once it has drafted one.
--
-- Separate from record_answers because they answer different questions: one is
-- what the person decided, the other is what the agent concluded from it. A
-- single function taking both would let a caller quietly rewrite the answers
-- while claiming to save a summary.
create or replace function draft_strategy(
  p_strategy   uuid,
  p_summary    text,
  p_pillar_mix jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_owner uuid; v_approved timestamptz;
begin
  select user_id, approved_at into v_owner, v_approved
    from strategies where id = p_strategy;

  if v_owner is null then
    raise exception 'no such strategy' using errcode = 'P0002';
  end if;
  -- Rewriting the reasoning under an approval somebody already gave would make
  -- the approval meaningless. Change means supersede.
  if v_approved is not null then
    raise exception 'already approved' using errcode = '55000';
  end if;

  update strategies
     set summary    = coalesce(p_summary, summary),
         pillar_mix = coalesce(p_pillar_mix, pillar_mix)
   where id = p_strategy;
end $$;

-- The person says yes. This is the only thing that unlocks production.
--
-- Deliberately NOT callable by the service role path: `auth.uid()` must match,
-- so the agent cannot approve its own work no matter what it decides. That is
-- the single most important line in this file.
create or replace function approve_strategy(p_strategy uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_owner uuid; v_brand uuid;
begin
  select user_id, brand_id into v_owner, v_brand
    from strategies where id = p_strategy;

  if v_owner is null then
    raise exception 'no such strategy' using errcode = 'P0002';
  end if;
  if (select auth.uid()) is distinct from v_owner then
    raise exception 'only the owner approves' using errcode = '42501';
  end if;

  -- One live strategy per brand. Approving this retires whatever it replaces,
  -- so "what is the agent working towards" has exactly one answer.
  update strategies
     set superseded_at = now()
   where brand_id = v_brand
     and id <> p_strategy
     and superseded_at is null;

  update strategies set approved_at = now()
   where id = p_strategy and approved_at is null;

  return p_strategy;
end $$;

-- Retires the live strategy so a new one can be drafted.
--
-- What "make next month more educational" actually does: the approved strategy
-- is kept, marked superseded, and a fresh draft begins. History stays readable,
-- and published content keeps pointing at the strategy it was made under.
create or replace function supersede_strategy(p_brand uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_owner uuid;
begin
  select user_id into v_owner from brands where id = p_brand;
  if v_owner is null then
    raise exception 'no such brand' using errcode = 'P0002';
  end if;
  if (select auth.uid()) is not null and (select auth.uid()) <> v_owner then
    raise exception 'not yours' using errcode = '42501';
  end if;

  update strategies set superseded_at = now()
   where brand_id = p_brand and superseded_at is null;
end $$;

-- What the agent is working towards right now, for the app to render.
create or replace function current_strategy(p_brand uuid)
returns table (
  id          uuid,
  goal        text,
  appetite    text,
  audience    text,
  cadence     smallint,
  summary     text,
  pillar_mix  jsonb,
  approved_at timestamptz,
  created_at  timestamptz
)
language sql
security definer
set search_path = public
as $$
  select s.id, s.goal, s.appetite, s.audience, s.cadence,
         s.summary, s.pillar_mix, s.approved_at, s.created_at
    from strategies s
    join brands b on b.id = s.brand_id
   where s.brand_id = p_brand
     and b.user_id = (select auth.uid())
     and s.superseded_at is null
   order by s.approved_at desc nulls last, s.created_at desc
   limit 1;
$$;

revoke execute on function record_answers(uuid, uuid, text, text, text, smallint) from anon, public;
revoke execute on function draft_strategy(uuid, text, jsonb)                      from anon, public;
revoke execute on function approve_strategy(uuid)                                 from anon, public;
revoke execute on function supersede_strategy(uuid)                               from anon, public;
revoke execute on function current_strategy(uuid)                                 from anon, public;

grant execute on function record_answers(uuid, uuid, text, text, text, smallint) to authenticated;
grant execute on function approve_strategy(uuid)                                  to authenticated;
grant execute on function supersede_strategy(uuid)                                to authenticated;
grant execute on function current_strategy(uuid)                                  to authenticated;
-- draft_strategy stays service-role only: the reasoning is the agent's to write.
