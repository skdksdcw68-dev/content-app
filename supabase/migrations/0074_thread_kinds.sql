-- A generation thread stays a generation thread.
--
-- Abel, 26 Sep 2026: "after u were on a chat where the video generation is
-- and after u left and open it again u gonna find it the normal chat, and on
-- the chats list i want it to be identified as well."
--
-- The app decided how to draw a thread from the ROUTE that opened it: pushed
-- from Home's video door meant generator, everything else meant chat. Reopen
-- the same thread from the chats list and the route says chat, so the feed,
-- the bar and send-is-generate all vanished. The thread itself has to carry
-- what it is.
alter table public.threads
  add column if not exists kind text not null default 'chat'
  check (kind in ('chat', 'generation'));

-- Set once by the owner, and only forward: a generation thread never quietly
-- becomes a chat again, because the transcript in it is generations.
create or replace function mark_thread_generation(p_thread uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update threads
     set kind = 'generation'
   where id = p_thread
     and user_id = (select auth.uid());
$$;

revoke execute on function mark_thread_generation(uuid) from anon, public;
grant  execute on function mark_thread_generation(uuid) to authenticated;

-- The list says which is which.
drop function if exists my_threads(int, uuid);
create or replace function my_threads(p_limit int default 30, p_brand uuid default null)
returns table (
  id         uuid,
  title      text,
  preview    text,
  updated_at timestamptz,
  brand_id   uuid,
  kind       text
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
         t.kind
    from threads t
   where t.user_id = (select auth.uid())
     and (p_brand is null or t.brand_id = p_brand or t.brand_id is null)
   order by t.updated_at desc
   limit greatest(1, least(p_limit, 100));
$$;

revoke execute on function my_threads(int, uuid) from anon, public;
grant  execute on function my_threads(int, uuid) to authenticated;
