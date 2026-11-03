-- What the chat remembers about a person across every conversation.
--
-- Abel, 3 Nov 2026: "It should remember every single thing." He told it that
-- "uk" meant "you know" and to forget about Drobe, and both were gone a few
-- messages later: each chat started from nothing but the brand's facts. After
-- each reply the model decides what is worth keeping (agent-chat
-- `updateMemory`), and every reply, the router and the campaign writer read it.
--
-- Written by the agent (service role) only. The person can read and delete
-- their own notes, so a Memory screen can list and remove them later. Gone with
-- the account.

create table if not exists public.person_memory (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  note       text not null check (char_length(note) between 1 and 300),
  created_at timestamptz not null default now()
);

create index if not exists person_memory_user_idx on public.person_memory (user_id, created_at);

alter table public.person_memory enable row level security;

drop policy if exists person_memory_read on public.person_memory;
create policy person_memory_read on public.person_memory for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists person_memory_forget on public.person_memory;
create policy person_memory_forget on public.person_memory for delete to authenticated
  using ((select auth.uid()) = user_id);

revoke all on public.person_memory from anon;
grant select, delete on public.person_memory to authenticated;
