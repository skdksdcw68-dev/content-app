-- Conversations that survive closing the app.
--
-- `threads` and `messages` have existed since 0002 and have never held a row.
-- The chat screen keeps its turns in SwiftUI `@State`, so the conversation dies
-- with the view: swipe the app away mid-plan and the agent has no idea what you
-- were talking about. For a product whose whole claim is that it keeps working
-- while the phone is closed, that is the wrong way round.
--
-- Two things make this more than an insert.
--
-- `messages` is ordered by `(thread_id, seq)` with a unique constraint, and seq
-- has to be allocated without two writers colliding. `max(seq) + 1` read in the
-- function and written a moment later is a race that shows up as a lost turn,
-- so the allocation happens inside one statement against the locked thread row.
--
-- And the RLS from 0002 is deliberately asymmetric: a person may insert their
-- own turns and nothing else, because an assistant message the client could
-- write is an assistant message the client could forge. So this is
-- `security definer` and every path checks ownership itself.

-- Finds the conversation to write into, making one if needed.
--
-- Titled from the first thing said, trimmed to something that fits a list. A
-- thread called "New chat" forever is a thread nobody can find again.
create or replace function open_thread(
  p_brand uuid default null,
  p_title text default ''
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := (select auth.uid());
  v_id   uuid;
begin
  if v_user is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  insert into threads (user_id, brand_id, title)
  values (
    v_user,
    p_brand,
    case
      when btrim(coalesce(p_title, '')) = '' then ''
      when length(p_title) > 60 then left(p_title, 57) || '...'
      else p_title
    end
  )
  returning id into v_id;

  return v_id;
end $$;

-- Appends one turn and returns its sequence number.
--
-- The `for update` is the point: it serialises writers on the thread row, so
-- two turns arriving together get 4 and 5 rather than both getting 4 and one of
-- them disappearing into the unique constraint.
create or replace function append_message(
  p_thread      uuid,
  p_role        text,
  p_text        text,
  p_render_hint jsonb default null,
  p_run         uuid default null
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
  v_seq   bigint;
begin
  select user_id into v_owner from threads where id = p_thread for update;

  if v_owner is null then
    raise exception 'no such thread' using errcode = 'P0002';
  end if;

  -- Callers are the app (as the person) and the agent function (as the service
  -- role, with auth.uid() null). Anyone else asking about somebody else's
  -- thread is refused rather than told whether it exists.
  if (select auth.uid()) is not null and (select auth.uid()) <> v_owner then
    raise exception 'not yours' using errcode = '42501';
  end if;

  if p_role not in ('user', 'assistant', 'system') then
    raise exception 'unknown role %', p_role using errcode = '22023';
  end if;

  select coalesce(max(seq), 0) + 1 into v_seq from messages where thread_id = p_thread;

  insert into messages (user_id, thread_id, run_id, seq, role, text, render_hint)
  values (v_owner, p_thread, p_run, v_seq, p_role::message_role, coalesce(p_text, ''), p_render_hint);

  -- So a thread list can be ordered by activity rather than by creation, which
  -- is what makes the one you were just in appear at the top.
  update threads set updated_at = now() where id = p_thread;

  return v_seq;
end $$;

-- The conversation, oldest first, for one thread this person owns.
create or replace function thread_messages(p_thread uuid, p_limit int default 200)
returns table (
  seq         bigint,
  role        text,
  text        text,
  render_hint jsonb,
  created_at  timestamptz
)
language sql
security definer
set search_path = public
as $$
  select m.seq, m.role::text, m.text, m.render_hint, m.created_at
    from messages m
    join threads t on t.id = m.thread_id
   where m.thread_id = p_thread
     and t.user_id = (select auth.uid())
   order by m.seq
   limit p_limit;
$$;

-- Recent conversations, newest activity first, with the last thing said.
create or replace function my_threads(p_limit int default 30)
returns table (
  id         uuid,
  title      text,
  preview    text,
  updated_at timestamptz
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
         t.updated_at
    from threads t
   where t.user_id = (select auth.uid())
   order by t.updated_at desc
   limit p_limit;
$$;

revoke execute on function open_thread(uuid, text)                   from anon, public;
revoke execute on function append_message(uuid, text, text, jsonb, uuid) from anon, public;
revoke execute on function thread_messages(uuid, int)                from anon, public;
revoke execute on function my_threads(int)                           from anon, public;

grant execute on function open_thread(uuid, text)                    to authenticated;
grant execute on function append_message(uuid, text, text, jsonb, uuid) to authenticated;
grant execute on function thread_messages(uuid, int)                 to authenticated;
grant execute on function my_threads(int)                            to authenticated;
