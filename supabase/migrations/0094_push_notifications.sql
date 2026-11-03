-- Push notifications (Abel, 3 Nov 2026): "a push notification when it finishes
-- generating a video, a photo, a voice, or a response".
--
-- The phone registers its APNs token here. When any job finishes, a trigger
-- calls the `notify` function, which sends the push through Apple. One trigger
-- rather than a call at each place a job ends: there are five of them, plus
-- the renderer on Fly.

create table if not exists public.push_devices (
  token        text primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  environment  text not null default 'production' check (environment in ('production', 'sandbox')),
  updated_at   timestamptz not null default now()
);
create index if not exists push_devices_user_idx on public.push_devices (user_id);
alter table public.push_devices enable row level security;

-- A token moves to whoever signed in on that phone last.
create or replace function public.register_push_device(p_token text, p_environment text default 'production')
returns void
language sql
security definer
set search_path = public
as $$
  insert into push_devices (token, user_id, environment, updated_at)
  select p_token, auth.uid(), coalesce(p_environment, 'production'), now()
  where auth.uid() is not null and length(p_token) between 32 and 200
  on conflict (token) do update
    set user_id = excluded.user_id, environment = excluded.environment, updated_at = now();
$$;
revoke execute on function public.register_push_device(text, text) from anon, public;
grant execute on function public.register_push_device(text, text) to authenticated;

create or replace function public.forget_push_device(p_token text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from push_devices where token = p_token and user_id = auth.uid();
$$;
revoke execute on function public.forget_push_device(text) from anon, public;
grant execute on function public.forget_push_device(text) to authenticated;

-- One push per job, or per set of pictures: the first insert wins, so two
-- pictures of a set finishing in the same instant still ping once.
create table if not exists public.push_sent (
  key      text primary key,
  sent_at  timestamptz not null default now()
);
alter table public.push_sent enable row level security;

alter table private.scheduler_config add column if not exists push_url text;

create or replace function private.push_when_run_ends()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare cfg record;
begin
  select * into cfg from private.scheduler_config where id;
  if cfg is null or not cfg.enabled or cfg.push_url is null then
    return new;
  end if;
  perform net.http_post(
    url     := cfg.push_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', cfg.cron_secret),
    body    := jsonb_build_object('run_id', new.id),
    timeout_milliseconds := 10000
  );
  return new;
exception when others then
  -- A push must never stop a job from finishing.
  return new;
end $$;

drop trigger if exists agent_runs_push on public.agent_runs;
create trigger agent_runs_push
  after update of status on public.agent_runs
  for each row
  when (new.status in ('succeeded', 'failed') and old.status is distinct from new.status)
  execute function private.push_when_run_ends();
