-- 0043: the operating loop, visible end to end.
--
-- Abel (17 Sep 2026): prove Content -> Plan -> Schedule -> Approval ->
-- Autopilot -> Prepare -> Publish -> Verify -> Analytics -> Learn, and show it.
-- Every stage here is read from rows the pipeline already writes; nothing is
-- a progress bar with no job behind it.
--
--   1. Plans and posts carry what a serious plan shows: objective, platforms,
--      CTA, hashtags.
--   2. activity_events: what Autocast (and you, and TikTok) did, written by
--      triggers on the rows that actually changed.
--   3. post_board(): one post with its target, job, media and stage.
--   4. autopilot_overview(): the machine's state for one brand.
--   5. Autopilot can be paused (publishing_on), and paused means paused.
--   6. Gaps found while tracing the loop: missing rate rows, publish failures
--      invisible to health, reschedule after the slot passed.

-- ------------------------------------------------------------ 1. plan fields

alter table content_plans add column if not exists objective text not null default '';
alter table content_plans add column if not exists platforms text[] not null default '{tiktok}';

alter table posts add column if not exists cta text not null default '';
alter table posts add column if not exists hashtags text[] not null default '{}';

-- The app may edit the words a person writes, CTA and hashtags included.
grant update (hook, script, concept, cta, hashtags) on posts to authenticated;

-- ------------------------------------------------------ 5. pause / resume

alter table brand_settings add column if not exists publishing_on boolean not null default true;

-- ------------------------------------------------------------ 2. activity

create table if not exists activity_events (
  id        bigserial primary key,
  user_id   uuid not null references auth.users on delete cascade,
  brand_id  uuid references brands on delete cascade,
  post_id   uuid references posts on delete cascade,
  kind      text not null,
  actor     text not null default 'autocast' check (actor in ('autocast', 'you', 'platform')),
  title     text not null,
  detail    text not null default '',
  at        timestamptz not null default now()
);
create index if not exists activity_brand_idx on activity_events (brand_id, at desc);
create index if not exists activity_post_idx on activity_events (post_id, at desc);

alter table activity_events enable row level security;
drop policy if exists own_activity on activity_events;
create policy own_activity on activity_events for select to authenticated
  using ((select auth.uid()) = user_id);
grant select on activity_events to authenticated;

create or replace function log_activity(
  p_user uuid, p_brand uuid, p_post uuid, p_kind text, p_actor text, p_title text, p_detail text default ''
) returns void
language sql security definer set search_path = public as $$
  insert into activity_events (user_id, brand_id, post_id, kind, actor, title, detail)
  values (p_user, p_brand, p_post, p_kind, p_actor, p_title, coalesce(p_detail, ''));
$$;
revoke execute on function log_activity(uuid, uuid, uuid, text, text, text, text) from anon, authenticated, public;

-- Targets: approval, upload, TikTok's answer.
create or replace function trg_target_activity() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_post posts;
begin
  select * into v_post from posts where id = new.post_id;

  if new.consent_id is not null and old.consent_id is distinct from new.consent_id then
    perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'approved', 'you',
      'You approved it', 'Visibility: ' || new.privacy::text);
  end if;

  if new.state is distinct from old.state then
    case new.state::text
      when 'uploading' then
        perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'publishing', 'autocast',
          'Publishing to ' || initcap(new.platform::text), '');
      when 'submitted' then
        perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'verifying', 'platform',
          initcap(new.platform::text) || ' received the video', 'Waiting for it to finish processing.');
      when 'published' then
        perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'published', 'platform',
          'Published on ' || initcap(new.platform::text),
          case when new.privacy::text = 'SELF_ONLY' then 'Visible only to you.' else '' end);
      when 'failed' then
        perform log_activity(new.user_id, v_post.brand_id, new.post_id, 'failed', 'autocast',
          'Couldn''t publish', coalesce(new.failure_reason, new.failure_code, ''));
        -- Publish failures used to live only on the target, so health never saw
        -- them. The post says so too now.
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

drop trigger if exists target_activity on post_targets;
create trigger target_activity after update on post_targets
  for each row execute function trg_target_activity();

-- Jobs: scheduled, held.
create or replace function trg_job_activity() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_post posts;
begin
  select p.* into v_post from posts p join post_targets t on t.post_id = p.id where t.id = new.post_target_id;

  if new.state = 'pending'
     and (tg_op = 'INSERT' or old.state is distinct from new.state or old.run_at is distinct from new.run_at) then
    perform log_activity(new.user_id, v_post.brand_id, v_post.id, 'scheduled', 'autocast',
      'Scheduled', to_char(new.run_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  elsif tg_op = 'UPDATE' and new.state = 'cancelled' and old.state is distinct from new.state then
    perform log_activity(new.user_id, v_post.brand_id, v_post.id, 'held', 'autocast',
      'Held before publishing', coalesce(new.last_error, ''));
  end if;
  return new;
end $$;

drop trigger if exists job_activity on publish_jobs;
create trigger job_activity after insert or update on publish_jobs
  for each row execute function trg_job_activity();

-- Posts: generation.
create or replace function trg_post_activity() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'sourcing' then
      perform log_activity(new.user_id, new.brand_id, new.id, 'generating', 'autocast', 'Making the video', '');
    elsif new.status = 'needs_approval' and old.status = 'sourcing' then
      perform log_activity(new.user_id, new.brand_id, new.id, 'generated', 'autocast', 'Video ready for your review', '');
    elsif new.status = 'failed' and old.status = 'sourcing' then
      perform log_activity(new.user_id, new.brand_id, new.id, 'failed', 'autocast',
        'Couldn''t make the video', coalesce(new.failure_reason, ''));
    end if;
  end if;
  return new;
end $$;

drop trigger if exists post_activity on posts;
create trigger post_activity after update on posts
  for each row execute function trg_post_activity();

-- Settings: pause and resume, and the AI-video switch.
create or replace function trg_settings_activity() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid;
begin
  select user_id into v_user from brands where id = new.brand_id;
  if new.publishing_on is distinct from old.publishing_on then
    perform log_activity(v_user, new.brand_id, null,
      case when new.publishing_on then 'resumed' else 'paused' end, 'you',
      case when new.publishing_on then 'Autopilot resumed' else 'Autopilot paused' end,
      case when new.publishing_on then 'Approved posts go out at their times.'
           else 'Nothing is published until you resume.' end);
  end if;
  if new.is_on is distinct from old.is_on then
    perform log_activity(v_user, new.brand_id, null, 'setting', 'you',
      case when new.is_on then 'AI videos turned on' else 'AI videos turned off' end, '');
  end if;
  return new;
end $$;

drop trigger if exists settings_activity on brand_settings;
create trigger settings_activity after update on brand_settings
  for each row execute function trg_settings_activity();

-- ------------------------------------------- 6. gaps found tracing the loop

-- A connection without a rate row is skipped by the claim forever.
insert into account_rate_state (connection_id)
select c.id from platform_connections c
 where not exists (select 1 from account_rate_state r where r.connection_id = c.id);

create or replace function trg_connection_rate_row() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into account_rate_state (connection_id) values (new.id) on conflict do nothing;
  return new;
end $$;
drop trigger if exists connection_rate_row on platform_connections;
create trigger connection_rate_row after insert on platform_connections
  for each row execute function trg_connection_rate_row();

-- Paused means paused: the claim skips a paused brand's jobs.
create or replace function claim_publish_jobs(
  p_worker text,
  p_batch  int      default 5,
  p_lease  interval default '10 minutes'
) returns setof publish_jobs
language plpgsql set search_path = public as $$
declare
  v_job   publish_jobs;
  v_taken int := 0;
begin
  for v_job in
    select j.*
      from publish_jobs j
     where j.state = 'pending'
       and j.run_at <= now()
       and j.expires_at > now()
       and exists (
         select 1 from post_targets t
           join posts p on p.id = t.post_id
           left join brand_settings s on s.brand_id = p.brand_id
          where t.id = j.post_target_id
            and coalesce(s.publishing_on, true)
       )
     order by j.run_at
     limit greatest(p_batch * 4, 20)
     for update of j skip locked
  loop
    exit when v_taken >= p_batch;

    update account_rate_state r
       set minute_window = greatest(r.minute_window, date_trunc('minute', now())),
           minute_count  = case when r.minute_window < date_trunc('minute', now())
                                then 1 else r.minute_count + 1 end,
           day_window    = greatest(r.day_window, current_date),
           day_count     = case when r.day_window < current_date
                                then 1 else r.day_count + 1 end
     where r.connection_id = v_job.connection_id
       and coalesce(r.cooldown_until, '-infinity') < now()
       and (r.minute_window < date_trunc('minute', now()) or r.minute_count < r.max_per_minute)
       and (r.day_window    < current_date               or r.day_count    < r.max_per_day);

    continue when not found;

    update publish_jobs
       set state       = 'claimed',
           claimed_by  = p_worker,
           lease_until = now() + p_lease,
           attempts    = attempts + 1
     where id = v_job.id
    returning * into v_job;

    v_taken := v_taken + 1;
    return next v_job;
  end loop;
end $$;
revoke execute on function claim_publish_jobs(text, int, interval) from anon, authenticated;

-- A missed window says why: paused is not "the publisher was unavailable".
create or replace function expire_publish_jobs()
returns int
language plpgsql set search_path = public as $$
declare v_n int;
begin
  with expired as (
    update publish_jobs j
       set state = 'failed', last_error = 'missed_window'
     where j.state = 'pending' and j.expires_at <= now()
    returning j.post_target_id
  )
  update post_targets t
     set state = 'failed',
         failure_code = 'missed_window',
         failure_reason = case
           when exists (select 1 from posts p join brand_settings s on s.brand_id = p.brand_id
                         where p.id = t.post_id and not s.publishing_on)
             then 'Autopilot was paused at its time, so it was not posted. Pick a new time to post it.'
           else 'The scheduled time passed while the publisher was unavailable. It was not posted late on purpose.'
         end
    from expired e
   where t.id = e.post_target_id;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke execute on function expire_publish_jobs() from anon, authenticated;

-- Generation also waits while paused.
create or replace function due_for_render(p_limit int default 10)
returns table (post_id uuid, user_id uuid, brand_id uuid, prompt text)
language sql
security definer
set search_path = public
as $$
  select p.id, p.user_id, p.brand_id,
         case when btrim(p.concept) <> '' then p.concept else p.hook end
    from posts p
    join brand_settings s on s.brand_id = p.brand_id
   where p.status = 'scheduled'
     and p.render_after is not null
     and p.render_after <= now()
     and p.media_strategy = 'generate'
     and s.is_on
     and s.publishing_on
     and not exists (
       select 1 from generation_jobs g
        where g.post_id = p.id
          and g.status in ('queued','submitted','running','succeeded')
     )
   order by p.scheduled_for
   limit p_limit;
$$;
revoke execute on function due_for_render(int) from anon, authenticated, public;

-- Pick a new time: for a post whose slot passed, or to post sooner. Approved
-- posts are re-queued at the new time; unapproved ones just move.
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
               and t.state in ('uploading', 'submitted', 'processing', 'published')) then
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
      update post_targets set state = 'pending', failure_code = null, failure_reason = null
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
revoke execute on function reschedule_post(uuid, timestamptz) from anon, public;
grant execute on function reschedule_post(uuid, timestamptz) to authenticated;

-- ------------------------------------------------------------ 3. post_board

-- One post, everything about it, and the stage it is at. The stage is derived
-- from the rows, in the order the pipeline moves through them.
create or replace function post_stage(
  p_post_status text, p_plan_status text, p_target_state text, p_consent boolean,
  p_job_state text, p_has_media boolean, p_generating boolean
) returns text
language sql immutable as $$
  select case
    when p_target_state = 'published' then 'published'
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

create or replace function post_board(p_brand uuid, p_plan uuid default null, p_post uuid default null)
returns jsonb
language sql stable security definer set search_path = public as $$
  with mine as (
    select p.*
      from posts p
     where p.brand_id = p_brand
       and p.user_id = auth.uid()
       and (p_plan is null or p.plan_id = p_plan)
       and (p_post is null or p.id = p_post)
       and (p_plan is not null or p_post is not null)
  ),
  rows as (
    select
      p.*,
      pl.status::text as plan_status,
      pl.title as plan_title,
      pi.name as pillar_name,
      t.id as target_id, t.state::text as target_state, t.caption as target_caption,
      t.hashtags as target_hashtags, t.privacy::text as privacy, t.consent_id is not null as consented,
      t.published_at, t.provider_post_id, t.provider_publish_id, t.failure_reason as target_failure,
      t.scheduled_for as target_run_at, t.platform::text as platform,
      c.username, c.status::text as connection_status,
      j.state::text as job_state, j.run_at, j.attempts, j.last_error,
      m.storage_bucket, m.storage_path, m.mime, m.byte_size, m.source::text as media_source,
      g.status::text as generation_status, g.error as generation_error
    from mine p
    left join content_plans pl on pl.id = p.plan_id
    left join content_pillars pi on pi.id = p.pillar_id
    left join lateral (
      select * from post_targets t where t.post_id = p.id order by (t.state = 'published') desc, t.id limit 1
    ) t on true
    left join platform_connections c on c.id = t.connection_id
    left join publish_jobs j on j.post_target_id = t.id
    left join lateral (
      select ma.* from post_assets pa join media_assets ma on ma.id = pa.asset_id
       where pa.post_target_id = t.id order by pa.ordinal limit 1
    ) m on true
    left join lateral (
      select g.status, g.error from generation_jobs g where g.post_id = p.id order by g.created_at desc limit 1
    ) g on true
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'plan_id', r.plan_id,
    'plan_title', r.plan_title,
    'day_index', r.day_index,
    'slot_index', r.slot_index,
    'format', r.format,
    'hook', r.hook,
    'caption', coalesce(nullif(r.target_caption, ''), r.script),
    'hashtags', case when coalesce(array_length(r.target_hashtags, 1), 0) > 0 then r.target_hashtags else r.hashtags end,
    'cta', r.cta,
    'concept', r.concept,
    'rationale', r.rationale,
    'pillar', r.pillar_name,
    'status', r.status,
    'media_strategy', r.media_strategy,
    'scheduled_for', coalesce(r.run_at, r.target_run_at, r.scheduled_for),
    'platform', coalesce(r.platform, 'tiktok'),
    'username', r.username,
    'connection_status', r.connection_status,
    'target_id', r.target_id,
    'target_state', r.target_state,
    'privacy', r.privacy,
    'approved', coalesce(r.consented, false),
    'published_at', r.published_at,
    'provider_post_id', r.provider_post_id,
    'job_state', r.job_state,
    'attempts', r.attempts,
    'problem', coalesce(r.target_failure, r.failure_reason, r.last_error,
                        case when r.generation_status = 'failed' then r.generation_error end),
    'media', case when r.storage_path is null then null else jsonb_build_object(
      'bucket', r.storage_bucket, 'path', r.storage_path, 'mime', r.mime,
      'bytes', r.byte_size, 'source', r.media_source) end,
    'generation', r.generation_status,
    'stage', post_stage(r.status::text, r.plan_status, r.target_state, coalesce(r.consented, false),
                        r.job_state, r.storage_path is not null,
                        r.generation_status in ('queued', 'submitted', 'running')),
    'activity', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'kind', a.kind, 'actor', a.actor, 'title', a.title, 'detail', a.detail, 'at', a.at
      ) order by a.at), '[]'::jsonb)
      from activity_events a where a.post_id = r.id and p_post is not null
    )
  ) order by r.scheduled_for nulls last, r.slot_index), '[]'::jsonb)
  from rows r;
$$;
revoke execute on function post_board(uuid, uuid, uuid) from anon, public;
grant execute on function post_board(uuid, uuid, uuid) to authenticated;

-- ------------------------------------------------------ 4. autopilot_overview

create or replace function autopilot_overview(p_brand uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_brand    brands;
  v_settings brand_settings;
  v_plan     content_plans;
  v_conn     platform_connections;
  v_result   jsonb;
  v_next     jsonb;
  v_last     jsonb;
  v_counts   jsonb;
  v_action   text;
  v_detail   text := '';
  v_waiting  int;
  v_attention int;
  v_ready    int;
begin
  select * into v_brand from brands where id = p_brand and user_id = auth.uid();
  if v_brand is null then
    raise exception 'that brand is not yours';
  end if;
  select * into v_settings from brand_settings where brand_id = p_brand;
  select * into v_plan from content_plans where brand_id = p_brand and status = 'active' limit 1;
  select * into v_conn from platform_connections where brand_id = p_brand
   order by (status = 'active') desc, connected_at desc limit 1;

  -- The next thing that will go out by itself.
  select jsonb_build_object('id', p.id, 'hook', p.hook, 'at', j.run_at, 'format', p.format)
    into v_next
    from publish_jobs j
    join post_targets t on t.id = j.post_target_id
    join posts p on p.id = t.post_id
   where p.brand_id = p_brand and j.state = 'pending' and j.run_at > now() - interval '5 minutes'
   order by j.run_at limit 1;

  select jsonb_build_object('id', p.id, 'hook', p.hook, 'at', t.published_at,
                            'privacy', t.privacy, 'provider_post_id', t.provider_post_id)
    into v_last
    from post_targets t join posts p on p.id = t.post_id
   where p.brand_id = p_brand and t.state = 'published'
   order by t.published_at desc nulls last limit 1;

  select count(*) into v_waiting
    from posts p
    join post_targets t on t.post_id = p.id
   where p.brand_id = p_brand and p.status = 'needs_approval' and t.consent_id is null
     and exists (select 1 from post_assets pa where pa.post_target_id = t.id);

  select count(*) into v_attention
    from posts p
    left join post_targets t on t.post_id = p.id
   where p.brand_id = p_brand
     and (p.status = 'failed' or t.state in ('failed', 'needs_reapproval'))
     and p.updated_at > now() - interval '14 days';

  select count(*) into v_ready
    from publish_jobs j join post_targets t on t.id = j.post_target_id join posts p on p.id = t.post_id
   where p.brand_id = p_brand and j.state = 'pending';

  v_counts := jsonb_build_object(
    'published', (select count(*) from post_targets t join posts p on p.id = t.post_id
                   where p.brand_id = p_brand and t.state = 'published'),
    'published_in_plan', (select count(*) from post_targets t join posts p on p.id = t.post_id
                   where v_plan.id is not null and p.plan_id = v_plan.id and t.state = 'published'),
    'in_plan', (select count(*) from posts p where v_plan.id is not null and p.plan_id = v_plan.id),
    'queued', v_ready,
    'waiting_for_you', v_waiting,
    'needs_attention', v_attention,
    'in_flight', (select count(*) from post_targets t join posts p on p.id = t.post_id
                   where p.brand_id = p_brand and t.state in ('uploading', 'submitted', 'processing'))
  );

  -- One sentence: what happens next, and whose move it is.
  if v_conn is null then
    v_action := 'connect';
  elsif v_conn.status <> 'active' then
    v_action := 'reconnect';
  elsif not coalesce(v_settings.publishing_on, true) then
    v_action := 'paused';
  elsif v_attention > 0 then
    v_action := 'fix';
  elsif v_waiting > 0 then
    v_action := 'review';
  elsif v_next is not null then
    v_action := 'publish_next';
  elsif v_plan.id is null then
    v_action := 'plan';
  else
    v_action := 'add_content';
  end if;

  v_result := jsonb_build_object(
    'brand', jsonb_build_object('id', v_brand.id, 'name', v_brand.name, 'timezone', v_brand.timezone),
    'publishing_on', coalesce(v_settings.publishing_on, true),
    'ai_videos_on', coalesce(v_settings.is_on, false),
    'requires_approval', coalesce(v_settings.requires_approval, true),
    'connection', case when v_conn is null then null else jsonb_build_object(
      'platform', v_conn.platform, 'username', v_conn.username, 'status', v_conn.status) end,
    'plan', case when v_plan.id is null then null else jsonb_build_object(
      'id', v_plan.id, 'title', v_plan.title, 'objective', v_plan.objective,
      'starts_on', v_plan.starts_on, 'days', v_plan.days, 'posts_per_day', v_plan.posts_per_day) end,
    'next_action', v_action,
    'next_post', v_next,
    'last_published', v_last,
    'counts', v_counts,
    'activity', (
      select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
        select a.kind, a.actor, a.title, a.detail, a.at, a.post_id, p.hook
          from activity_events a left join posts p on p.id = a.post_id
         where a.brand_id = p_brand
         order by a.at desc limit 20
      ) x
    )
  );
  return v_result;
end $$;
revoke execute on function autopilot_overview(uuid) from anon, public;
grant execute on function autopilot_overview(uuid) to authenticated;

-- The app writes publishing_on itself.
grant update (publishing_on) on brand_settings to authenticated;
