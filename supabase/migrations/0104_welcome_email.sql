-- One welcome email per person, sent by the welcome-email function through
-- Resend when an address is first confirmed on their account (sign-up by
-- email code, or Apple/Google giving one). push_sent-style dedupe: the table
-- makes a second call for the same person do nothing.

create table if not exists public.welcome_sent (
  user_id uuid primary key,
  sent_at timestamptz not null default now()
);
alter table public.welcome_sent enable row level security;

alter table private.scheduler_config add column if not exists welcome_url text;

create or replace function private.welcome_on_confirm()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare cfg record;
begin
  select * into cfg from private.scheduler_config where id;
  if cfg is null or not cfg.enabled or cfg.welcome_url is null then
    return new;
  end if;
  perform net.http_post(
    url     := cfg.welcome_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', cfg.cron_secret),
    body    := jsonb_build_object('user_id', new.id),
    timeout_milliseconds := 10000
  );
  return new;
exception when others then
  -- An email must never stop somebody from signing up.
  return new;
end $$;

drop trigger if exists auth_users_welcome on auth.users;
create trigger auth_users_welcome
  after insert or update of email, email_confirmed_at on auth.users
  for each row
  when (new.email is not null and new.email_confirmed_at is not null and not coalesce(new.is_anonymous, false))
  execute function private.welcome_on_confirm();
