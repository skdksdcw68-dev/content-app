-- 0056: chat settings -- the owner's standing instructions, and clearing chats.
--
-- Abel, 23 Sep 2026: "the chat is really perfect, but make sure we can have
-- some chat settings." Two things a person expects to be able to set: how
-- the chat should talk to them (a sentence or two, read into every reply),
-- and a way to delete a conversation or all of them.

alter table brand_settings add column if not exists chat_instructions text;

-- The owner's own words, capped so a pasted essay cannot crowd out the
-- system prompt. Only the brand's owner may write it.
create or replace function set_chat_instructions(p_brand uuid, p_text text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from brands b where b.id = p_brand and b.user_id = (select auth.uid())) then
    raise exception 'Not your brand.' using errcode = '42501';
  end if;
  update brand_settings
     set chat_instructions = nullif(left(btrim(coalesce(p_text, '')), 1000), '')
   where brand_id = p_brand;
end $$;

revoke execute on function set_chat_instructions(uuid, text) from anon, public;
grant  execute on function set_chat_instructions(uuid, text) to authenticated;

-- One conversation, if it is theirs. Messages go with it by cascade.
create or replace function delete_thread(p_thread uuid)
returns void
language sql
security definer
set search_path = public
as $$
  delete from threads t
   where t.id = p_thread
     and t.user_id = (select auth.uid());
$$;

revoke execute on function delete_thread(uuid) from anon, public;
grant  execute on function delete_thread(uuid) to authenticated;

-- Every conversation of theirs, for one brand or for all of them.
create or replace function clear_my_threads(p_brand uuid default null)
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
       and (p_brand is null or t.brand_id = p_brand or t.brand_id is null)
    returning 1
  )
  select count(*) into v_count from gone;
  return v_count;
end $$;

revoke execute on function clear_my_threads(uuid) from anon, public;
grant  execute on function clear_my_threads(uuid) to authenticated;
