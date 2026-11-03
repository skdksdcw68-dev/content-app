-- Scheduled drops (Abel, 3 Nov 2026): "Generate me five outfits ... send it at
-- exactly 2 am ... It can produce whenever, but it must send it at the exact
-- time I asked." And: "send it every day, mark it on a calendar."
--
-- The chat saves a DRAFT with the jobs already worked out; the person confirms
-- or changes the time on the phone (save_schedule). run-schedules, woken every
-- minute, starts each drop early enough, keeps it out of the chat, and posts it
-- with a ping at the minute it is due.

create table if not exists public.schedules (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  thread_id    uuid references public.threads(id) on delete set null,
  status       text not null default 'draft' check (status in ('draft', 'active', 'paused', 'cancelled', 'done')),
  request      text not null,
  summary      text not null,
  -- The generation inputs, exactly as the chat would have started them.
  inputs       jsonb not null,
  -- What words to send with it ("a caption for each"), or null.
  with_text    text,
  timezone     text not null default 'UTC',
  starts_at    timestamptz not null,
  time_of_day  time not null,
  repeat       text not null default 'none' check (repeat in ('none', 'daily', 'weekdays', 'weekly', 'custom')),
  days         smallint[] not null default '{}',
  ends_at      timestamptz,
  ends_after   int check (ends_after is null or ends_after > 0),
  delivered    int not null default 0,
  next_at      timestamptz,
  options      jsonb not null default '{"calendar": true, "ping": true, "fresh": true}',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists schedules_due_idx on public.schedules (next_at) where status = 'active';
create index if not exists schedules_user_idx on public.schedules (user_id);
alter table public.schedules enable row level security;
drop policy if exists schedules_read_own on public.schedules;
create policy schedules_read_own on public.schedules for select using (user_id = auth.uid());

-- One delivery of a schedule. Unique per time, so two ticks never make it twice.
create table if not exists public.schedule_drops (
  id            uuid primary key default gen_random_uuid(),
  schedule_id   uuid not null references public.schedules(id) on delete cascade,
  due_at        timestamptz not null,
  status        text not null default 'making' check (status in ('making', 'delivered', 'failed', 'skipped')),
  run_ids       uuid[] not null default '{}',
  text          text,
  error         text,
  created_at    timestamptz not null default now(),
  delivered_at  timestamptz,
  unique (schedule_id, due_at)
);
alter table public.schedule_drops enable row level security;
drop policy if exists schedule_drops_read_own on public.schedule_drops;
create policy schedule_drops_read_own on public.schedule_drops for select
  using (exists (select 1 from public.schedules s where s.id = schedule_id and s.user_id = auth.uid()));

-- The first delivery after p_after, in the schedule's own time zone, so 2 AM
-- stays 2 AM across daylight saving. Null when it does not repeat.
create or replace function public.schedule_next(
  p_after timestamptz, p_repeat text, p_days smallint[], p_time time, p_tz text
) returns timestamptz
language sql
stable
set search_path = public
as $$
  select min((d::date + p_time) at time zone p_tz)
  from generate_series((p_after at time zone p_tz)::date, (p_after at time zone p_tz)::date + 8, interval '1 day') d
  where p_repeat <> 'none'
    and ((d::date + p_time) at time zone p_tz) > p_after
    and (
      p_repeat = 'daily'
      or (p_repeat = 'weekdays' and extract(dow from d) between 1 and 5)
      or (p_repeat in ('weekly', 'custom') and extract(dow from d)::smallint = any(p_days))
    );
$$;

-- Confirming or changing a schedule from the phone.
create or replace function public.save_schedule(
  p_id uuid,
  p_starts_at timestamptz,
  p_timezone text,
  p_repeat text,
  p_days smallint[],
  p_ends_at timestamptz,
  p_ends_after int,
  p_options jsonb
) returns public.schedules
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.schedules;
  tz text := coalesce(nullif(p_timezone, ''), 'UTC');
  local_time time;
  v_days smallint[] := coalesce(p_days, '{}');
  v_next timestamptz;
begin
  select * into v_row from schedules where id = p_id and user_id = auth.uid() for update;
  if v_row.id is null then raise exception 'not found'; end if;
  if p_repeat not in ('none', 'daily', 'weekdays', 'weekly', 'custom') then raise exception 'repeat'; end if;
  perform now() at time zone tz;  -- an unknown zone fails here, not later
  local_time := (p_starts_at at time zone tz)::time;
  if p_repeat = 'weekly' and cardinality(v_days) = 0 then
    v_days := array[extract(dow from (p_starts_at at time zone tz))::smallint];
  end if;
  if p_repeat = 'custom' and cardinality(v_days) = 0 then raise exception 'days'; end if;

  -- The first one at the time chosen; a time already gone means the next one.
  v_next := case
    when p_starts_at > now() then p_starts_at
    when p_repeat = 'none' then now()
    else schedule_next(now(), p_repeat, v_days, local_time, tz)
  end;

  update schedules set
    status = 'active', starts_at = p_starts_at, timezone = tz, time_of_day = local_time,
    repeat = p_repeat, days = v_days, ends_at = p_ends_at, ends_after = p_ends_after,
    options = coalesce(p_options, schedules.options), next_at = v_next, updated_at = now()
  where id = p_id
  returning * into v_row;

  -- A drop already being made for the old time arrives at the new one.
  update schedule_drops set due_at = v_next where schedule_id = p_id and status = 'making';
  return v_row;
end $$;
revoke execute on function public.save_schedule(uuid, timestamptz, text, text, smallint[], timestamptz, int, jsonb) from anon, public;
grant execute on function public.save_schedule(uuid, timestamptz, text, text, smallint[], timestamptz, int, jsonb) to authenticated;

create or replace function public.cancel_schedule(p_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update schedules set status = 'cancelled', next_at = null, updated_at = now()
  where id = p_id and user_id = auth.uid();
  update schedule_drops set status = 'skipped'
  where schedule_id = p_id and status = 'making'
    and exists (select 1 from schedules s where s.id = p_id and s.user_id = auth.uid());
$$;
revoke execute on function public.cancel_schedule(uuid) from anon, public;
grant execute on function public.cancel_schedule(uuid) to authenticated;

-- "Pause all" on the Scheduled page.
create or replace function public.pause_schedules(p_paused boolean)
returns void
language sql
security definer
set search_path = public
as $$
  update schedules set
    status = case when p_paused then 'paused' else 'active' end,
    next_at = case when p_paused then next_at
                   else coalesce(case when next_at > now() then next_at end,
                                 schedule_next(now(), repeat, days, time_of_day, timezone), next_at) end,
    updated_at = now()
  where user_id = auth.uid() and status = case when p_paused then 'active' else 'paused' end;
$$;
revoke execute on function public.pause_schedules(boolean) from anon, public;
grant execute on function public.pause_schedules(boolean) to authenticated;

-- Woken every minute, like the publisher and the job worker.
alter table private.scheduler_config add column if not exists schedules_url text;

create or replace function private.tick_schedules()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare cfg record;
begin
  select * into cfg from private.scheduler_config where id;
  if cfg is null or not cfg.enabled or cfg.schedules_url is null then return; end if;
  -- Nothing due soon: no call at all.
  if not exists (select 1 from schedules where status = 'active' and next_at < now() + interval '3 hours')
     and not exists (select 1 from schedule_drops where status = 'making') then
    return;
  end if;
  perform net.http_post(
    url     := cfg.schedules_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', cfg.cron_secret),
    body    := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
end $$;
revoke execute on function private.tick_schedules() from anon, authenticated, public;

select cron.schedule('run-schedules', '* * * * *', 'select private.tick_schedules()');
