-- Chats you can get back, pin, rename, search inside, and share (Abel, 8 Nov 2026).
--
--  * Deleting a chat moves it to Recently Deleted. It can be restored for 30
--    days, then a nightly job removes it for good. "Delete now" and "Empty"
--    remove it at once.
--  * A chat can be pinned to the top and renamed.
--  * Search looks inside the messages, not only at titles.
--  * Share makes a link (https://netrocast.com/s/?c=TOKEN) that shows the
--    conversation on a web page. Stop sharing turns the link off.

alter table threads add column if not exists deleted_at timestamptz;
alter table threads add column if not exists pinned_at  timestamptz;

create index if not exists threads_user_deleted_idx
  on threads (user_id, deleted_at desc) where deleted_at is not null;

-- Share links. Only reached through the functions below.
create table if not exists thread_shares (
  token      text primary key,
  thread_id  uuid not null references threads(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

alter table thread_shares enable row level security;

create unique index if not exists thread_shares_live_idx
  on thread_shares (thread_id) where revoked_at is null;

-- The strongest thing a conversation made: a video over a picture over a sound.
create or replace function thread_media(p_thread uuid, p_user uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
           when bool_or(a.kind = 'video') then 'video'
           when bool_or(a.kind = 'image') then 'image'
           when bool_or(a.kind = 'audio') then 'audio'
         end
    from artifacts a
   where a.thread_id = p_thread
     and a.user_id = p_user
     and a.kind in ('image', 'video', 'audio')
     and a.status = 'ready';
$$;

revoke execute on function thread_media(uuid, uuid) from anon, public, authenticated;

-- The list: live chats only, pinned ones first.
drop function if exists my_threads(integer, uuid);
create function my_threads(p_limit integer default 30, p_brand uuid default null)
returns table(id uuid, title text, preview text, updated_at timestamptz,
              brand_id uuid, kind text, media text, pinned boolean)
language sql
stable
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
         thread_media(t.id, t.user_id),
         t.pinned_at is not null
    from threads t
   where t.user_id = (select auth.uid())
     and t.deleted_at is null
     and (p_brand is null or t.brand_id = p_brand or t.brand_id is null)
   order by (t.pinned_at is not null) desc, t.pinned_at desc nulls last, t.updated_at desc
   limit greatest(1, least(p_limit, 100));
$$;

revoke execute on function my_threads(integer, uuid) from anon, public;
grant  execute on function my_threads(integer, uuid) to authenticated;

-- Words found anywhere in a chat: its title or any message. The preview is
-- the part of the message around the words.
create or replace function search_threads(p_query text, p_brand uuid default null, p_limit integer default 50)
returns table(id uuid, title text, preview text, updated_at timestamptz,
              brand_id uuid, kind text, media text, pinned boolean)
language sql
stable
security definer
set search_path = public
as $$
  with q as (
    select btrim(coalesce(p_query, '')) as words,
           '%' || replace(replace(replace(btrim(coalesce(p_query, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pattern
  )
  select t.id,
         t.title,
         coalesce(
           (select substr(m.text, greatest(1, strpos(lower(m.text), lower(q.words)) - 40), 180)
              from messages m
             where m.thread_id = t.id and m.text ilike q.pattern
             order by m.seq desc limit 1),
           (select m.text from messages m
             where m.thread_id = t.id and m.text <> ''
             order by m.seq desc limit 1),
           ''),
         t.updated_at,
         t.brand_id,
         t.kind,
         thread_media(t.id, t.user_id),
         t.pinned_at is not null
    from threads t, q
   where t.user_id = (select auth.uid())
     and t.deleted_at is null
     and length(q.words) > 0
     and (p_brand is null or t.brand_id = p_brand or t.brand_id is null)
     and (t.title ilike q.pattern
          or exists (select 1 from messages m where m.thread_id = t.id and m.text ilike q.pattern))
   order by (t.pinned_at is not null) desc, t.updated_at desc
   limit greatest(1, least(p_limit, 100));
$$;

revoke execute on function search_threads(text, uuid, integer) from anon, public;
grant  execute on function search_threads(text, uuid, integer) to authenticated;

-- Recently Deleted: the last 30 days, newest first.
create or replace function my_deleted_threads(p_brand uuid default null)
returns table(id uuid, title text, preview text, updated_at timestamptz,
              deleted_at timestamptz, kind text, media text)
language sql
stable
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
         t.deleted_at,
         t.kind,
         thread_media(t.id, t.user_id)
    from threads t
   where t.user_id = (select auth.uid())
     and t.deleted_at is not null
     and t.deleted_at > now() - interval '30 days'
     and (p_brand is null or t.brand_id = p_brand or t.brand_id is null)
   order by t.deleted_at desc
   limit 200;
$$;

revoke execute on function my_deleted_threads(uuid) from anon, public;
grant  execute on function my_deleted_threads(uuid) to authenticated;

-- Delete moves a chat to Recently Deleted. Same name and signature as before,
-- so older builds keep working: their delete now lands in the bin too.
create or replace function delete_thread(p_thread uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update threads t
     set deleted_at = now(), pinned_at = null
   where t.id = p_thread
     and t.user_id = (select auth.uid())
     and t.deleted_at is null;
  update thread_shares s
     set revoked_at = now()
   where s.thread_id = p_thread
     and s.user_id = (select auth.uid())
     and s.revoked_at is null;
$$;

-- Clear all chats also goes to Recently Deleted.
create or replace function clear_my_threads(p_brand uuid default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer;
begin
  with gone as (
    update threads t
       set deleted_at = now(), pinned_at = null
     where t.user_id = (select auth.uid())
       and t.deleted_at is null
       and (p_brand is null or t.brand_id = p_brand or t.brand_id is null)
    returning 1
  )
  select count(*) into v_count from gone;
  update thread_shares s
     set revoked_at = now()
   where s.user_id = (select auth.uid())
     and s.revoked_at is null
     and s.thread_id in (select t.id from threads t where t.user_id = (select auth.uid()) and t.deleted_at is not null);
  return v_count;
end $$;

create or replace function restore_thread(p_thread uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update threads t
     set deleted_at = null
   where t.id = p_thread
     and t.user_id = (select auth.uid())
     and t.deleted_at is not null;
$$;

-- Gone for good, now: one chat from the bin, or all of it.
create or replace function purge_thread(p_thread uuid)
returns void
language sql
security definer
set search_path = public
as $$
  delete from threads t
   where t.id = p_thread
     and t.user_id = (select auth.uid())
     and t.deleted_at is not null;
$$;

create or replace function empty_deleted_threads()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer;
begin
  with gone as (
    delete from threads t
     where t.user_id = (select auth.uid())
       and t.deleted_at is not null
    returning 1
  )
  select count(*) into v_count from gone;
  return v_count;
end $$;

create or replace function pin_thread(p_thread uuid, p_pinned boolean)
returns void
language sql
security definer
set search_path = public
as $$
  update threads t
     set pinned_at = case when p_pinned then now() else null end
   where t.id = p_thread
     and t.user_id = (select auth.uid())
     and t.deleted_at is null;
$$;

create or replace function rename_thread(p_thread uuid, p_title text)
returns void
language sql
security definer
set search_path = public
as $$
  update threads t
     set title = left(btrim(coalesce(p_title, '')), 120)
   where t.id = p_thread
     and t.user_id = (select auth.uid())
     and length(btrim(coalesce(p_title, ''))) > 0;
$$;

-- The link's token: the one already shared, or a new one.
create or replace function share_thread(p_thread uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_token text;
begin
  if not exists (
    select 1 from threads t
     where t.id = p_thread and t.user_id = (select auth.uid()) and t.deleted_at is null
  ) then
    raise exception 'That chat could not be found.';
  end if;

  select s.token into v_token
    from thread_shares s
   where s.thread_id = p_thread and s.revoked_at is null;
  if v_token is not null then return v_token; end if;

  v_token := left(replace(gen_random_uuid()::text, '-', ''), 22);
  insert into thread_shares (token, thread_id, user_id)
  values (v_token, p_thread, (select auth.uid()));
  return v_token;
end $$;

create or replace function unshare_thread(p_thread uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update thread_shares s
     set revoked_at = now()
   where s.thread_id = p_thread
     and s.user_id = (select auth.uid())
     and s.revoked_at is null;
$$;

-- What the web page shows: the title and the words of the conversation.
-- Readable by anyone who has the link, while it is shared and not deleted.
create or replace function shared_thread(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'title', coalesce(nullif(t.title, ''), 'A chat on Postpilot'),
           'shared_at', s.created_at,
           'messages', coalesce((
             select jsonb_agg(jsonb_build_object('role', m.role::text, 'text', m.text) order by m.seq)
               from messages m
              where m.thread_id = t.id
                and m.role in ('user', 'assistant')
                and m.text <> ''
           ), '[]'::jsonb))
    from thread_shares s
    join threads t on t.id = s.thread_id
   where s.token = p_token
     and s.revoked_at is null
     and t.deleted_at is null;
$$;

revoke execute on function delete_thread(uuid), clear_my_threads(uuid), restore_thread(uuid),
                           purge_thread(uuid), empty_deleted_threads(), pin_thread(uuid, boolean),
                           rename_thread(uuid, text), share_thread(uuid), unshare_thread(uuid)
  from anon, public;
grant execute on function delete_thread(uuid), clear_my_threads(uuid), restore_thread(uuid),
                          purge_thread(uuid), empty_deleted_threads(), pin_thread(uuid, boolean),
                          rename_thread(uuid, text), share_thread(uuid), unshare_thread(uuid)
  to authenticated;

revoke execute on function shared_thread(text) from public;
grant  execute on function shared_thread(text) to anon, authenticated;

-- Every night, chats deleted more than 30 days ago go for good.
select cron.unschedule(j.jobid) from cron.job j where j.jobname = 'purge-deleted-chats';
select cron.schedule(
  'purge-deleted-chats',
  '23 3 * * *',
  $$delete from public.threads where deleted_at is not null and deleted_at < now() - interval '30 days'$$
);

notify pgrst, 'reload schema';
