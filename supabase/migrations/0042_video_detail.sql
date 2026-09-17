-- One video, in much more detail -- and read often enough to have a curve.
--
-- Abel, 17 Sep 2026, on the Video analysis screen: "the detail isn't good",
-- "why doesn't it get the views details", and of Chat, "when you ask it for
-- details it doesn't know". Two causes:
--
--   1. Readings every 6 hours. A video posted this morning had one reading, so
--      there was no views-over-time at all. Now every hour: the numbers move
--      fastest in a video's first days, and that is exactly when the curve is
--      worth having. Four accounts, one call each, is well inside TikTok's
--      limits.
--   2. post_analytics said what a video got, not how that compares. It now
--      also returns every hourly reading and a `context` block -- rank among
--      the account's videos, share of all views, the other videos' medians for
--      views, engagement, length, hashtags and caption length, the hour it
--      went out, how long it has been live, and the account's best posting
--      block when there is enough data to say. The screen and Chat both read
--      this, so neither makes up a comparison.

select cron.unschedule('fetch-metrics') where exists (
  select 1 from cron.job where jobname = 'fetch-metrics');

select cron.schedule('fetch-metrics', '17 * * * *', $job$select tick_metrics()$job$);

create or replace function post_analytics(p_brand uuid, p_video text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tz  text;
  v_out jsonb;
begin
  select coalesce(nullif(b.timezone, ''), 'UTC') into v_tz
    from brands b
   where b.id = p_brand and b.user_id = (select auth.uid());
  if v_tz is null then
    return null;
  end if;

  with
  latest as (
    select distinct on (s.video_id)
           s.video_id, s.platform, s.post_target_id, s.posted_at, s.title, s.description,
           s.cover_url, s.share_url, s.duration_s, s.views, s.likes, s.comments, s.shares, s.taken_at
      from post_metric_snapshots s
     where s.brand_id = p_brand
     order by s.video_id, s.taken_at desc
  ),
  enriched as (
    select l.*, p.format, cp.name as pillar,
           (l.likes + l.comments + l.shares)::numeric / nullif(l.views, 0) as engagement,
           (select count(*) from regexp_matches(coalesce(l.description, l.title, ''), '#[[:alnum:]_]+', 'g'))::int as hashtags,
           length(coalesce(nullif(l.description, ''), l.title, '')) as caption_length
      from latest l
      left join post_targets t     on t.id = l.post_target_id
      left join posts p            on p.id = t.post_id
      left join content_pillars cp on cp.id = p.pillar_id
  ),
  me as (select * from enriched where video_id = p_video),
  others as (select * from enriched where video_id <> p_video),
  groups as (
    select 'account' as scope, 'All your videos' as label, count(*)::int as posts,
           percentile_cont(0.5) within group (order by e.views) as median_views,
           percentile_cont(0.5) within group (order by e.engagement) as median_engagement
      from others e
    union all
    select 'format', 'Same format (' || m.format || ')', count(e.*)::int,
           percentile_cont(0.5) within group (order by e.views),
           percentile_cont(0.5) within group (order by e.engagement)
      from me m join others e on e.format = m.format
     where m.format is not null group by m.format
    union all
    select 'pillar', 'Same theme (' || m.pillar || ')', count(e.*)::int,
           percentile_cont(0.5) within group (order by e.views),
           percentile_cont(0.5) within group (order by e.engagement)
      from me m join others e on e.pillar = m.pillar
     where m.pillar is not null group by m.pillar
    union all
    select 'platform', 'Same platform', count(e.*)::int,
           percentile_cont(0.5) within group (order by e.views),
           percentile_cont(0.5) within group (order by e.engagement)
      from me m join others e on e.platform = m.platform
     where (select count(distinct platform) from enriched) > 1
     group by m.platform
  ),
  timed as (
    select (extract(hour from (posted_at at time zone v_tz))::int / 3) * 3 as block, views
      from enriched where posted_at is not null
  ),
  blocks as (
    select block, count(*)::int as n, percentile_cont(0.5) within group (order by views) as med
      from timed group by block
  ),
  overall as (
    select count(*)::int as n, percentile_cont(0.5) within group (order by views) as med from timed
  ),
  best as (
    select b.block, b.n, b.med / nullif(o.med, 0) - 1 as lift
      from blocks b cross join overall o
     where b.n >= 3 and o.n >= 8
     order by b.med desc
     limit 1
  )
  select case when not exists (select 1 from me) then null else jsonb_build_object(
    'video', (select jsonb_build_object(
                'video_id', video_id, 'platform', platform, 'title', title, 'description', description,
                'cover_url', cover_url, 'share_url', share_url, 'duration_s', duration_s,
                'posted_at', _iso(posted_at), 'measured_at', _iso(taken_at),
                'views', views, 'likes', likes, 'comments', comments, 'shares', shares,
                'engagement_rate', round(engagement, 4),
                'from_autocast', post_target_id is not null)
                from me),
    'availability', (select platform_metric_support(platform) from me),
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object('day', day, 'views', views, 'likes', likes,
                                          'comments', comments, 'shares', shares) order by day)
        from (
          select distinct on ((s.taken_at at time zone v_tz)::date)
                 (s.taken_at at time zone v_tz)::date as day, s.views, s.likes, s.comments, s.shares
            from post_metric_snapshots s
           where s.brand_id = p_brand and s.video_id = p_video
           order by (s.taken_at at time zone v_tz)::date, s.taken_at desc
        ) d), '[]'::jsonb),
    -- One reading per hour, the last taken in that hour.
    'readings', coalesce((
      select jsonb_agg(jsonb_build_object('at', _iso(h.at), 'views', h.views, 'likes', h.likes,
                                          'comments', h.comments, 'shares', h.shares) order by h.at)
        from (
          select distinct on (date_trunc('hour', s.taken_at))
                 s.taken_at as at, s.views, s.likes, s.comments, s.shares
            from post_metric_snapshots s
           where s.brand_id = p_brand and s.video_id = p_video
           order by date_trunc('hour', s.taken_at), s.taken_at desc
        ) h), '[]'::jsonb),
    'context', jsonb_build_object(
      'videos', (select count(*) from enriched),
      'rank', (select count(*) + 1 from enriched e where e.views > (select views from me)),
      'others', (select count(*) from others),
      'share_of_views', (select round((select views from me)::numeric / nullif(sum(views), 0), 4) from enriched),
      'median_views', (select percentile_cont(0.5) within group (order by views) from others),
      'median_engagement', (select percentile_cont(0.5) within group (order by engagement) from others),
      'median_duration', (select percentile_cont(0.5) within group (order by duration_s) from others where duration_s is not null),
      'median_hashtags', (select percentile_cont(0.5) within group (order by hashtags) from others),
      'median_caption_length', (select percentile_cont(0.5) within group (order by caption_length) from others),
      'hashtags', (select hashtags from me),
      'caption_length', (select caption_length from me),
      'posted_hour', (select extract(hour from (posted_at at time zone v_tz))::int from me),
      'hours_live', (select round((extract(epoch from (now() - posted_at)) / 3600)::numeric, 1) from me),
      'timezone', v_tz,
      'best_hour', (select jsonb_build_object('slot', block, 'posts', n, 'lift', round(lift::numeric, 3))
                      from best where lift >= 0.15)),
    'post', (
      select jsonb_build_object(
               'hook', p.hook, 'caption', t.caption, 'concept', p.concept, 'rationale', p.rationale,
               'format', p.format, 'pillar', cp.name, 'campaign', pl.title, 'hashtags', t.hashtags,
               'media_strategy', p.media_strategy, 'privacy', t.privacy,
               'scheduled_for', _iso(p.scheduled_for), 'published_at', _iso(t.published_at))
        from me
        join post_targets t on t.id = me.post_target_id
        join posts p on p.id = t.post_id
        left join content_pillars cp on cp.id = p.pillar_id
        left join content_plans pl on pl.id = p.plan_id),
    'media', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', a.kind, 'source', a.source, 'provider', a.provider, 'model', a.model,
               'duration_ms', a.duration_ms, 'width', a.width, 'height', a.height) order by pa.ordinal)
        from me
        join post_assets pa on pa.post_target_id = me.post_target_id
        join media_assets a on a.id = pa.asset_id), '[]'::jsonb),
    'comparisons', coalesce((
      select jsonb_agg(to_jsonb(g)) from groups g where g.posts >= 3), '[]'::jsonb)
  ) end into v_out;

  return v_out;
end $$;

revoke execute on function post_analytics(uuid, text) from anon, public;
grant  execute on function post_analytics(uuid, text) to authenticated;
