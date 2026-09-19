-- 0050: the brand questionnaire, and deleting a post.
--
--   brands.profile   Answers from the Brand page, keyed by question id:
--                    {"goal": {"title": "Main goal", "answers": ["Downloads"]}, ...}
--                    Stored with their titles and labels, so every reader (the
--                    planner, the caption writer, chat) can print them as
--                    "Main goal: Downloads" without knowing the question set.
--
--   delete_post      Removes a post you made, and everything hanging off it.
--                    Refused while it is on its way to TikTok -- deleting the
--                    row would not stop an upload already started. A video
--                    already on TikTok stays there; only Autocast forgets it.

alter table brands add column if not exists profile jsonb not null default '{}'::jsonb;

create or replace function delete_post(p_post uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner uuid;
begin
  select user_id into v_owner from posts where id = p_post;
  if v_owner is null or v_owner <> auth.uid() then
    raise exception 'That post is not yours.';
  end if;

  if exists (select 1 from post_targets
              where post_id = p_post
                and state in ('claimed', 'uploading', 'submitted', 'processing')) then
    raise exception 'It is being sent to TikTok right now. Try again in a minute.';
  end if;

  -- The RESTRICT links, in an order that satisfies them.
  delete from post_assets
   where post_target_id in (select id from post_targets where post_id = p_post);
  update post_targets set consent_id = null where post_id = p_post and consent_id is not null;
  delete from consent_records
   where post_target_id in (select id from post_targets where post_id = p_post);

  delete from posts where id = p_post;
end $$;
revoke execute on function delete_post(uuid) from anon, public;
grant execute on function delete_post(uuid) to authenticated;
