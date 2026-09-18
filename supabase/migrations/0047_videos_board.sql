-- 0047: Home lists the videos you have made.
--
-- Abel (18 Sep 2026): "lets just put videos we made on there, can be a draft
-- or whatever". post_board() gains p_videos: every post with a video
-- attached, newest first, whatever its stage.

drop function if exists post_board(uuid, uuid, uuid);

create or replace function post_board(p_brand uuid, p_plan uuid default null, p_post uuid default null, p_videos boolean default false)
returns jsonb
language sql stable security definer set search_path = public as $$
  with mine as (
    select p.*
      from posts p
     where p.brand_id = p_brand
       and p.user_id = auth.uid()
       and (p_plan is null or p.plan_id = p_plan)
       and (p_post is null or p.id = p_post)
       and (p_plan is not null or p_post is not null or p_videos)
       -- Home: every post that has a video, newest first.
       and (not p_videos or exists (
         select 1 from post_targets t join post_assets pa on pa.post_target_id = t.id where t.post_id = p.id))
     order by p.updated_at desc
     limit case when p_videos then 60 else 10000 end
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
  ) order by case when p_videos then r.updated_at end desc nulls last, r.scheduled_for nulls last, r.slot_index), '[]'::jsonb)
  from rows r;
$$;
revoke execute on function post_board(uuid, uuid, uuid, boolean) from anon, public;
grant execute on function post_board(uuid, uuid, uuid, boolean) to authenticated;
