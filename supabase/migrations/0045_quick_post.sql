-- 0045: posting without a plan, TikTok-style.
--
-- Abel (18 Sep 2026): a connected account is enough to post -- no brand setup
-- in the way -- write the caption yourself, let AI improve it, post now or
-- send to TikTok drafts, in original quality.
--
-- Drafts go through the same queue as posts, so nothing depends on the phone
-- staying open: a target now says which TikTok route it takes, and a video
-- that reached the creator's inbox has its own state.

alter type publish_state add value if not exists 'sent_to_inbox';

alter table post_targets add column if not exists publish_mode text not null default 'DIRECT_POST'
  check (publish_mode in ('DIRECT_POST', 'UPLOAD_TO_DRAFT'));

create or replace function post_stage(
  p_post_status text, p_plan_status text, p_target_state text, p_consent boolean,
  p_job_state text, p_has_media boolean, p_generating boolean
) returns text
language sql immutable as $$
  select case
    when p_target_state = 'published' then 'published'
    when p_target_state = 'sent_to_inbox' then 'in_drafts'
    when p_target_state in ('failed', 'needs_reapproval') or p_post_status = 'failed'
      or (p_job_state in ('failed', 'cancelled') and coalesce(p_target_state, '') <> 'published') then 'needs_attention'
    when p_target_state in ('submitted', 'processing') then 'verifying'
    when p_target_state = 'uploading' or p_job_state = 'claimed' then 'publishing'
    when p_consent and p_job_state = 'pending' then 'ready_to_publish'
    when p_consent then 'approved'
    when p_post_status = 'sourcing' or p_generating then 'generating'
    when p_has_media then 'ready_for_review'
    when p_plan_status in ('draft', 'proposed') then 'draft'
    when p_post_status = 'scheduled' then 'scheduled'
    else 'draft'
  end;
$$;

create or replace function trg_target_activity() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_post posts;
  v_drafts boolean := new.publish_mode = 'UPLOAD_TO_DRAFT';
begin
  select * into v_post from posts where id = new.post_id;

  if new.consent_id is not null and old.consent_id is distinct from new.consent_id then
    perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'approved', 'you',
      case when v_drafts then 'You sent it to your TikTok drafts' else 'You approved it' end,
      case when v_drafts then '' else 'Visibility: ' || new.privacy::text end);
  end if;

  if new.state is distinct from old.state then
    case new.state::text
      when 'uploading' then
        perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'publishing', 'autocast',
          case when v_drafts then 'Sending to your ' || initcap(new.platform::text) || ' drafts'
               else 'Publishing to ' || initcap(new.platform::text) end, 'Original file, no re-compression.');
      when 'submitted' then
        perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'verifying', 'platform',
          initcap(new.platform::text) || ' received the video', 'Waiting for it to finish processing.');
      when 'published' then
        perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'published', 'platform',
          'Published on ' || initcap(new.platform::text),
          case when new.privacy::text = 'SELF_ONLY' then 'Visible only to you.' else '' end);
      when 'sent_to_inbox' then
        perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'published', 'platform',
          'In your ' || initcap(new.platform::text) || ' drafts',
          'Open ' || initcap(new.platform::text) || ' to add sound or effects and post it.');
      when 'failed' then
        perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'failed', 'autocast',
          'Couldn''t publish', coalesce(new.failure_reason, new.failure_code, ''));
        if v_post.status not in ('posted', 'failed') then
          update posts set status = 'failed',
                           failure_reason = coalesce(new.failure_reason, new.failure_code, 'publish failed')
           where id = new.post_id;
        end if;
      when 'needs_reapproval' then
        perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'needs_reapproval', 'autocast',
          'Held: it changed after you approved it', 'Approve it again to post this version.');
      else null;
    end case;
  end if;
  return new;
end $$;

-- A draft sent to the inbox is finished as far as Autocast is concerned.
create or replace function reschedule_post(p_post uuid, p_at timestamptz)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_post   posts;
  v_target post_targets;
  v_job    uuid;
begin
  select * into v_post from posts where id = p_post;
  if v_post is null or v_post.user_id <> auth.uid() then
    raise exception 'that post is not yours';
  end if;
  if v_post.status = 'posted' then
    raise exception 'that post has already gone out';
  end if;
  if exists (select 1 from post_targets t where t.post_id = p_post
               and t.state in ('uploading', 'submitted', 'processing', 'published', 'sent_to_inbox')) then
    raise exception 'that post is already being published';
  end if;
  if p_at < now() + interval '2 minutes' then
    raise exception 'pick a time at least two minutes from now';
  end if;

  update posts
     set scheduled_for = p_at,
         status = case when status = 'failed' then
                    case when exists (select 1 from post_targets t where t.post_id = p_post and t.consent_id is not null)
                         then 'scheduled'::post_status else 'needs_approval'::post_status end
                  else status end,
         failure_reason = case when status = 'failed' then null else failure_reason end
   where id = p_post;

  for v_target in select * from post_targets where post_id = p_post loop
    if v_target.state in ('failed', 'cancelled') then
      update post_targets set state = 'pending', failure_code = null, failure_reason = null,
                              provider_publish_id = null
       where id = v_target.id;
    end if;
    if v_target.consent_id is not null and v_target.state <> 'needs_reapproval' then
      v_job := schedule_publish(v_target.id, p_at);
    else
      update post_targets set scheduled_for = p_at where id = v_target.id;
    end if;
  end loop;

  perform log_activity(v_post.user_id, v_post.brand_id, p_post, 'rescheduled', 'you', 'New time set',
    to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

  return jsonb_build_object('post_id', p_post, 'scheduled_for', p_at, 'queued', v_job is not null);
end $$;
