-- What a conversation MADE, and one place for everything that was made.
--
-- Abel, 29 Sep 2026: "after you generate with the chat, there is no 'Video' or
-- 'Generation' or 'Library' called or a badge. We probably need that thing."
--
-- The chats list knew a thread was a generation (`kind`, 0074) but not what
-- it had made, so the best it could draw was a small wand. Now it says Video,
-- Image or Audio -- the thing the thread actually produced -- and a thread
-- that is a generator but has not made anything yet says Generation.
--
-- And there was no place where the things themselves lived together: a picture
-- made on Tuesday was somewhere in a conversation you would have to remember.
-- `my_library` is every picture, video and piece of audio this person has
-- made, newest first, from any conversation.

-- ---------------------------------------------------------------- threads

-- Returned columns change, so the function is dropped first (42P13).
drop function if exists my_threads(int, uuid);
create or replace function my_threads(p_limit int default 30, p_brand uuid default null)
returns table (
  id         uuid,
  title      text,
  preview    text,
  updated_at timestamptz,
  brand_id   uuid,
  kind       text,
  media      text
)
language sql
security definer
set search_path = public
as $$
  select t.id,
         t.title,
         coalesce((
           select m.text from messages m
            where m.thread_id = t.id and m.text <> ''
            order by m.seq desc limit 1
         ), ''),
         t.updated_at,
         t.brand_id,
         t.kind,
         -- The strongest thing the conversation made: a video over a picture
         -- over a sound. Null when it made none of them.
         (select case
                   when bool_or(a.kind = 'video') then 'video'
                   when bool_or(a.kind = 'image') then 'image'
                   when bool_or(a.kind = 'audio') then 'audio'
                 end
            from artifacts a
           where a.thread_id = t.id
             and a.user_id = t.user_id
             and a.kind in ('image', 'video', 'audio')
             and a.status = 'ready')
    from threads t
   where t.user_id = (select auth.uid())
     and (p_brand is null or t.brand_id = p_brand or t.brand_id is null)
   order by t.updated_at desc
   limit greatest(1, least(p_limit, 100));
$$;

revoke execute on function my_threads(int, uuid) from anon, public;
grant  execute on function my_threads(int, uuid) to authenticated;

-- ---------------------------------------------------------------- library

-- Same columns as `artifact(p_id)`, so the app decodes them with the model it
-- already has. Only what is finished and has a file: a picture still being
-- made is a row in a conversation, not something to put on a shelf.
create or replace function my_library(p_kind text default null, p_limit int default 120)
returns table (
  id uuid, kind text, title text, status text, version int, parent_id uuid,
  storage_path text, mime text, byte_size bigint, body jsonb,
  provider text, model text, estimated_cost jsonb, actual_cost jsonb, created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select a.id, a.kind, a.title, a.status, a.version, a.parent_id,
         a.storage_path, a.mime, a.byte_size, a.body,
         a.provider, a.model, a.estimated_cost, a.actual_cost, a.created_at
    from artifacts a
   where a.user_id = (select auth.uid())
     and a.kind in ('image', 'video', 'audio')
     and a.status = 'ready'
     and a.storage_path is not null
     and (p_kind is null or a.kind = p_kind)
   order by a.created_at desc
   limit greatest(1, least(p_limit, 300));
$$;

revoke execute on function my_library(text, int) from anon, public;
grant  execute on function my_library(text, int) to authenticated;
