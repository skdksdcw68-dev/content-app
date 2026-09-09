-- Work that outlives the connection that asked for it.
--
-- Everything the product promises beyond a chat reply needs this. Deep
-- research, a thirty-day plan, a campaign, a document, a package of assets --
-- none of them fit in the 150 seconds an Edge Function gets, and all of them
-- have to survive somebody swiping the app away.
--
-- `agent_runs` and `agent_events` have existed since 0002 and `claim_agent_runs`
-- since 0003, both unused. What was missing is what a run is FOR: the tables
-- describe an execution with no description of the work. So this adds `kind`
-- and `input`, the steps that carry a run forward, and the read-back that lets
-- a conversation reconstruct itself.
--
-- Deliberately NOT a Fly container. The plan called for one and it is the right
-- shape eventually, but it costs money this project does not have, and the
-- pattern that publishes posts every minute -- pg_cron waking an Edge Function
-- that claims work with a lease -- already survives in production. A run
-- advances one step per tick; a long job is many ticks. The same tables and the
-- same claim function serve a real worker later without a migration.

alter table agent_runs add column if not exists kind text;
alter table agent_runs add column if not exists input jsonb not null default '{}'::jsonb;
alter table agent_runs add column if not exists result jsonb;
-- Where the run got to. A step is not a status: a run is `running` for its
-- whole life while the step moves through understanding, researching, writing.
alter table agent_runs add column if not exists step text;
alter table agent_runs add column if not exists run_after timestamptz not null default now();

comment on column agent_runs.kind is
  'What this run is: research, plan, campaign, document, package. The executor switches on it.';
comment on column agent_runs.step is
  'Where it got to. Distinct from status -- a run stays `running` while the step advances.';

create index if not exists agent_runs_due_idx
  on agent_runs (run_after)
  where status in ('queued', 'running');

-- Starts a run, and says so in the same breath.
--
-- The first event is written here rather than by the executor so a run is never
-- observable as existing-but-silent: somebody who opens the app between the
-- request and the first tick sees "queued", not an empty panel.
create or replace function start_agent_run(
  p_user   uuid,
  p_thread uuid,
  p_kind   text,
  p_input  jsonb default '{}'::jsonb,
  p_brand  uuid default null,
  p_model  text default 'gpt-4.1-mini'
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  insert into agent_runs (user_id, thread_id, brand_id, status, model, kind, input, step)
  values (p_user, p_thread, p_brand, 'queued', p_model, p_kind, coalesce(p_input, '{}'::jsonb), 'queued')
  returning id into v_id;

  insert into agent_events (run_id, seq, user_id, type, payload)
  values (v_id, 1, p_user, 'status', jsonb_build_object('step', 'queued', 'detail', 'Queued'));

  return v_id;
end $$;

-- Appends one event and returns its sequence number.
--
-- `(run_id, seq)` is the primary key, so allocation has to be serialised or two
-- events arriving together collide and one is lost. Same `for update` on the
-- run row as `append_message` uses on the thread, for the same reason.
create or replace function append_agent_event(
  p_run     uuid,
  p_type    text,
  p_payload jsonb default '{}'::jsonb
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_user uuid; v_seq integer;
begin
  select user_id into v_user from agent_runs where id = p_run for update;
  if v_user is null then
    raise exception 'no such run' using errcode = 'P0002';
  end if;

  select coalesce(max(seq), 0) + 1 into v_seq from agent_events where run_id = p_run;

  insert into agent_events (run_id, seq, user_id, type, payload)
  values (p_run, v_seq, v_user, p_type, coalesce(p_payload, '{}'::jsonb));

  return v_seq;
end $$;

-- Moves a run to its next step, and records that it moved.
--
-- One function rather than two writes, because a step that changed without an
-- event is a step nobody watching can see -- and the entire point of this table
-- is that somebody who left and came back can reconstruct what happened.
create or replace function advance_agent_run(
  p_run    uuid,
  p_step   text,
  p_detail text,
  p_after  interval default '0 seconds'
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update agent_runs
     set step = p_step,
         status = 'running',
         run_after = now() + p_after,
         claimed_by = null,
         lease_until = null
   where id = p_run;

  perform append_agent_event(p_run, 'status',
    jsonb_build_object('step', p_step, 'detail', p_detail));
end $$;

-- The run is over, one way or the other.
create or replace function finish_agent_run(
  p_run    uuid,
  p_status text,
  p_result jsonb default null,
  p_error  text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status not in ('succeeded', 'failed', 'cancelled', 'waiting_on_user') then
    raise exception 'bad status %', p_status using errcode = '22023';
  end if;

  update agent_runs
     set status      = p_status::agent_run_status,
         result      = coalesce(p_result, result),
         error       = p_error,
         step        = p_status,
         claimed_by  = null,
         lease_until = null,
         finished_at = case when p_status = 'waiting_on_user' then null else now() end
   where id = p_run;

  perform append_agent_event(
    p_run,
    case when p_status = 'succeeded' then 'done' else 'error' end,
    jsonb_build_object('status', p_status, 'error', p_error, 'result', p_result)
  );
end $$;

-- Runs ready for another tick.
--
-- `run_after` is what makes a long job cheap: a step that is waiting on a
-- provider sets it minutes ahead, and the executor skips it until then instead
-- of burning a tick to learn nothing.
create or replace function due_agent_runs(p_limit int default 3)
returns table (id uuid, user_id uuid, thread_id uuid, brand_id uuid, kind text, step text, input jsonb, attempts smallint)
language sql
security definer
set search_path = public
as $$
  select r.id, r.user_id, r.thread_id, r.brand_id, r.kind, r.step, r.input, r.attempts
    from agent_runs r
   where r.status in ('queued', 'running')
     and r.run_after <= now()
     and (r.lease_until is null or r.lease_until < now())
     and r.attempts < 6
   order by r.run_after
   limit p_limit;
$$;

-- Everything that happened on a run, for a conversation rebuilding itself.
--
-- `p_after` is what makes reconnection free: the client remembers the last seq
-- it drew and asks for what came after, so a dropped connection replays nothing
-- and needs no server-side session.
create or replace function run_events(p_run uuid, p_after int default 0)
returns table (seq int, type text, payload jsonb, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select e.seq, e.type, e.payload, e.created_at
    from agent_events e
    join agent_runs r on r.id = e.run_id
   where e.run_id = p_run
     and r.user_id = (select auth.uid())
     and e.seq > p_after
   order by e.seq;
$$;

-- What is still working, so the app can show it on return.
create or replace function my_running_agent_runs()
returns table (id uuid, thread_id uuid, kind text, step text, status text, created_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select r.id, r.thread_id, r.kind, r.step, r.status::text, r.created_at
    from agent_runs r
   where r.user_id = (select auth.uid())
     and r.status in ('queued', 'running', 'waiting_on_user')
   order by r.created_at desc
   limit 20;
$$;

revoke execute on function start_agent_run(uuid, uuid, text, jsonb, uuid, text) from anon, authenticated, public;
revoke execute on function append_agent_event(uuid, text, jsonb)                from anon, authenticated, public;
revoke execute on function advance_agent_run(uuid, text, text, interval)        from anon, authenticated, public;
revoke execute on function finish_agent_run(uuid, text, jsonb, text)            from anon, authenticated, public;
revoke execute on function due_agent_runs(int)                                  from anon, authenticated, public;
revoke execute on function run_events(uuid, int)                                from anon, public;
revoke execute on function my_running_agent_runs()                              from anon, public;

grant execute on function run_events(uuid, int)      to authenticated;
grant execute on function my_running_agent_runs()    to authenticated;

-- Readable by their owner so Realtime can stream them straight to the app.
-- Written only through the functions above: an event the client could insert is
-- a progress line the client could invent, and the whole value of this table is
-- that every line in it happened.
alter table agent_runs   enable row level security;
alter table agent_events enable row level security;

drop policy if exists agent_runs_read   on agent_runs;
drop policy if exists agent_events_read on agent_events;

create policy agent_runs_read on agent_runs for select to authenticated
  using ((select auth.uid()) = user_id);
create policy agent_events_read on agent_events for select to authenticated
  using ((select auth.uid()) = user_id);
