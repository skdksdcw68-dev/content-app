-- Attachments, and closing a gap in who may speak for the agent.
--
-- 1. A person can now attach pictures to a chat turn. They upload straight to
--    their own folder in the private `artifacts` bucket, under `uploads/`, and
--    nowhere else: the agent's own output lives beside it at
--    `${user}/${artifact}/...` and must stay unwritable by the client, because
--    a result the client could overwrite is a result it could forge.
--
-- 2. `append_message` was granted to `authenticated` and accepted any role. The
--    comment in agent-chat said clients could write only their own turns; the
--    function did not enforce it, so an app session could write an "assistant"
--    turn -- with a render hint pointing at whatever it liked -- into its own
--    conversation. Nothing trusted those rows to authorise anything, which is
--    why this was not worse. It is still the agent's voice, and only the agent
--    gets to use it.

-- Uploads: insert only, own folder, `uploads/` only. No update policy, so an
-- existing object cannot be replaced; no delete, so a reference cannot vanish
-- from under a run that is using it.
drop policy if exists artifacts_owner_upload on storage.objects;
create policy artifacts_owner_upload on storage.objects for insert to authenticated
  with check (
    bucket_id = 'artifacts'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and (storage.foldername(name))[2] = 'uploads'
  );

-- Pictures from a phone are a few megabytes once compressed; generated video
-- is the largest thing this bucket holds.
update storage.buckets set file_size_limit = 200 * 1024 * 1024 where id = 'artifacts';

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

  -- A person writes their own turns and nothing else, and the only thing they
  -- may attach to one is the list of files they attached.
  if (select auth.uid()) is not null then
    if p_role <> 'user' then
      raise exception 'only the agent writes its own turns' using errcode = '42501';
    end if;
    if p_render_hint is not null and p_render_hint->>'kind' is distinct from 'attachments' then
      raise exception 'that hint is the agent''s to write' using errcode = '42501';
    end if;
    if p_run is not null then
      raise exception 'runs are the agent''s to link' using errcode = '42501';
    end if;
  end if;

  select coalesce(max(seq), 0) + 1 into v_seq from messages where thread_id = p_thread;

  insert into messages (user_id, thread_id, run_id, seq, role, text, render_hint)
  values (v_owner, p_thread, p_run, v_seq, p_role::message_role, coalesce(p_text, ''), p_render_hint);

  -- So a thread list can be ordered by activity rather than by creation, which
  -- is what makes the one you were just in appear at the top.
  update threads set updated_at = now() where id = p_thread;

  return v_seq;
end $$;

revoke execute on function append_message(uuid, text, text, jsonb, uuid) from anon, public;
grant  execute on function append_message(uuid, text, text, jsonb, uuid) to authenticated;
