-- Likes and dislikes on Chat's answers.
--
-- Abel, 17 Sep 2026: "the chat is actually dumb... add a like, dislike and copy
-- response thing". A rating is only worth collecting if it is kept with what
-- was asked and what was answered, so the bad ones can be read later and the
-- prompts fixed against real failures rather than guesses.

create table if not exists chat_feedback (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users on delete cascade,
  thread_id  uuid references threads on delete set null,
  rating     text not null check (rating in ('up', 'down')),
  -- For a dislike: what was wrong, from a short list or typed.
  reason     text,
  asked      text,
  reply      text not null,
  created_at timestamptz not null default now()
);

create index if not exists chat_feedback_user_idx on chat_feedback (user_id, created_at desc);

alter table chat_feedback enable row level security;

drop policy if exists chat_feedback_own on chat_feedback;
create policy chat_feedback_own on chat_feedback for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

grant select, insert, delete on chat_feedback to authenticated;
