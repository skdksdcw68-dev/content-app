-- Conversations belong to the app they are about.
--
-- Autocast runs the marketing for several apps, and each has its own plan, its
-- own accounts and its own memory. Its conversations are no different: the
-- chat list under Remi should not show the chat where last week's ad for
-- another app was made. Filtered rather than split -- a thread with no brand
-- (everything written before today) still shows up, because hiding somebody's
-- history to introduce a feature is not a trade worth making.

create or replace function my_threads(p_limit int default 30, p_brand uuid default null)
returns table (
  id         uuid,
  title      text,
  preview    text,
  updated_at timestamptz,
  brand_id   uuid
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
         t.brand_id
    from threads t
   where t.user_id = (select auth.uid())
     and (p_brand is null or t.brand_id is null or t.brand_id = p_brand)
   order by t.updated_at desc
   limit p_limit;
$$;

revoke execute on function my_threads(int, uuid) from anon, public;
grant execute on function my_threads(int, uuid) to authenticated;
