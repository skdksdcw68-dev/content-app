-- The walls of the house (Abel, 5 Nov 2026: "even OpenAI and Claude have those
-- limits"). Not guesses about what anyone means -- the model still decides
-- that -- but how much one person can send, attach and run at once, so one
-- account cannot burn the month before the usage meter catches it.
--
-- One row per limit, one column per plan (plans_catalog.tier 0 free, 1 pro,
-- 2 max, 3 ultra). Edited here or from the admin panel; the app and the
-- server read it, so a number changes without an app update.
create table if not exists public.app_limits (
  key text primary key,
  free numeric not null,
  pro numeric not null,
  max numeric not null,
  ultra numeric not null,
  note text not null default ''
);

alter table public.app_limits enable row level security;
drop policy if exists "limits are public" on public.app_limits;
create policy "limits are public" on public.app_limits for select using (true);

insert into public.app_limits (key, free, pro, max, ultra, note) values
  ('message_chars',         20000, 20000, 20000, 20000, 'Longest message, in characters'),
  ('pictures_per_message',     10,    10,    10,    10, 'Pictures attached to one message'),
  ('messages_per_minute',      20,    20,    20,    20, 'Messages in any 60 seconds'),
  ('voice_note_seconds',      300,   300,   300,   300, 'Longest voice note'),
  ('video_upload_seconds',    600,   600,   600,   600, 'Longest video sent in for its words'),
  ('video_seconds',             0,    30,    60,   120, 'Longest video made'),
  ('pictures_per_request',      0,     4,     8,    12, 'Pictures made from one request'),
  ('jobs_at_once',              0,     2,     4,     8, 'Things being made at the same time'),
  ('series_running',            0,     1,     3,    10, 'Series running at once'),
  ('scheduled_waiting',         0,    10,    30,   100, 'Scheduled drops waiting')
on conflict (key) do nothing;

-- How many messages this person sent in the last few seconds, for the rate
-- limit. An index on (user_id, created_at) keeps it a lookup, not a scan.
create index if not exists messages_user_recent_idx on public.messages (user_id, created_at desc);

create or replace function public.recent_user_messages(p_user uuid, p_seconds int)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.messages
  where user_id = p_user and role = 'user' and created_at > now() - make_interval(secs => p_seconds);
$$;
revoke all on function public.recent_user_messages(uuid, int) from public, anon, authenticated;
