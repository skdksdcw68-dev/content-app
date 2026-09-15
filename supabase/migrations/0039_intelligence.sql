-- Analytics as the intelligence centre: what happened, why, what is changing,
-- and what to do next.
--
-- Abel's brief (15 Sep 2026) asks four things of this screen, and the rule under
-- all of them is the one this project keeps relearning: never invent a number.
-- So everything here is computed from readings that were actually taken, and
-- every figure carries whether it is complete.
--
-- How a figure for a period is made. TikTok reports running totals per video,
-- not views per day. The views a video gained between two moments is the last
-- reading before the second minus the last reading before the first. Where a
-- video had no reading before the first moment and was already posted, that
-- gain is UNKNOWN, not zero -- history only starts when Autocast started
-- reading -- and the period is marked incomplete rather than quietly
-- undercounted. A video posted inside the period starts from zero, which is
-- true.
--
-- Learning is written by `fetch-metrics` (_shared/learning.ts), deterministic
-- statistics with minimum sample sizes; nothing here asks a model for a
-- conclusion. Recommendations come only from those findings, and applying one
-- writes a measured fact into `brand_memory`, which the planner and Chat both
-- read -- that is the loop: post, reading, finding, recommendation, plan, post.

-- ------------------------------------------------------------ richer readings

alter table post_metric_snapshots
  add column if not exists platform    text not null default 'tiktok',
  add column if not exists duration_s  integer,
  add column if not exists cover_url   text,
  add column if not exists share_url   text,
  add column if not exists description text;

alter table account_metric_snapshots
  add column if not exists platform text not null default 'tiktok';

create index if not exists post_metric_snapshots_brand_video_idx
  on post_metric_snapshots (brand_id, video_id, taken_at desc);
create index if not exists account_metric_snapshots_conn_idx
  on account_metric_snapshots (connection_id, taken_at desc);

-- Timestamps leave as plain UTC ISO text, one shape, so every client parses them
-- the same way.
create or replace function _iso(p timestamptz)
returns text
language sql
immutable
as $$
  select to_char(p at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
$$;

-- What each platform actually gives an app. "derived" is computed from actual
-- numbers (engagement rate), never estimated. Anything else is unavailable, and
-- the app says so rather than showing a zero.
create or replace function platform_metric_support(p_platform text)
returns jsonb
language sql
immutable
as $$
  select case p_platform
    when 'tiktok' then jsonb_build_object(
      'views', 'actual', 'likes', 'actual', 'comments', 'actual', 'shares', 'actual',
      'followers_gained', 'actual', 'engagement_rate', 'derived',
      'reach', 'unavailable', 'saves', 'unavailable', 'avg_watch_time', 'unavailable',
      'avg_retention', 'unavailable', 'profile_visits', 'unavailable',
      'link_clicks', 'unavailable', 'conversions', 'unavailable')
    else jsonb_build_object(
      'views', 'unavailable', 'likes', 'unavailable', 'comments', 'unavailable', 'shares', 'unavailable',
      'followers_gained', 'unavailable', 'engagement_rate', 'unavailable',
      'reach', 'unavailable', 'saves', 'unavailable', 'avg_watch_time', 'unavailable',
      'avg_retention', 'unavailable', 'profile_visits', 'unavailable',
      'link_clicks', 'unavailable', 'conversions', 'unavailable')
  end;
$$;

-- ------------------------------------------------------------ learning objects

create table if not exists insights (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users on delete cascade,
  brand_id      uuid not null references brands on delete cascade,
  -- Which test found it, stable across runs: "duration", "format:video".
  key           text not null,
  statement     text not null,
  metric        text not null default 'median views',
  -- Winner median over loser median, minus one. 0.28 is +28%.
  lift          numeric not null,
  sample_size   integer not null,
  confidence    text not null check (confidence in ('low','medium','high')),
  evidence      jsonb not null default '{}'::jsonb,
  period_start  timestamptz,
  period_end    timestamptz,
  platforms     text[] not null default '{}',
  content_types text[] not null default '{}',
  status        text not null default 'active' check (status in ('active','retired')),
  computed_at   timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  unique (brand_id, key)
);

create table if not exists recommendations (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  brand_id    uuid not null references brands on delete cascade,
  insight_id  uuid references insights on delete set null,
  key         text not null,
  title       text not null,
  because     text not null,
  confidence  text not null check (confidence in ('low','medium','high')),
  -- { fact: what Apply writes into brand_memory, brief: what Add to plan starts from }
  action      jsonb not null default '{}'::jsonb,
  status      text not null default 'open'
                check (status in ('open','applied','planned','ignored','retired')),
  memory_id   uuid references brand_memory on delete set null,
  acted_at    timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (brand_id, key)
);

alter table insights        enable row level security;
alter table recommendations enable row level security;

-- Read by the owner; written by the learning job and by act_on_recommendation.
-- A finding the client could write is a finding the planner would trust.
drop policy if exists insights_read on insights;
create policy insights_read on insights for select to authenticated
  using ((select auth.uid()) = user_id);
drop policy if exists recommendations_read on recommendations;
create policy recommendations_read on recommendations for select to authenticated
  using ((select auth.uid()) = user_id);

grant select on insights        to authenticated;
grant select on recommendations to authenticated;

-- ------------------------------------------------------------ the report

create or replace function analytics_report(
  p_brand    uuid,
  p_from     date,
  p_to       date,
  p_platform text default null,
  p_format   text default null,
  p_pillar   uuid default null,
  p_plan     uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tz        text;
  v_days      int;
  v_step      int;
  v_buckets   int;
  v_prev_from date;
  v_prev_to   date;
  v_filtered  boolean := (p_format is not null or p_pillar is not null or p_plan is not null);
  v_out       jsonb;
begin
  select coalesce(nullif(b.timezone, ''), 'UTC') into v_tz
    from brands b
   where b.id = p_brand and b.user_id = (select auth.uid());
  if v_tz is null then
    return null;
  end if;
  if p_to < p_from then
    raise exception 'The end date is before the start date.' using errcode = '22023';
  end if;
  if p_to - p_from > 730 then
    raise exception 'Choose a range of two years or less.' using errcode = '22023';
  end if;

  v_days    := p_to - p_from + 1;
  -- Readable points, whatever the range: days up to a month, weeks up to six
  -- months, 30-day blocks beyond that.
  v_step    := case when v_days <= 31 then 1 when v_days <= 182 then 7 else 30 end;
  v_buckets := ceil(v_days::numeric / v_step)::int;
  v_prev_to   := p_from - 1;
  v_prev_from := p_from - v_days;

  with
  latest as (
    select distinct on (s.video_id)
           s.video_id, s.connection_id, s.platform, s.post_target_id, s.posted_at,
           s.title, s.description, s.cover_url, s.share_url, s.duration_s,
           s.views, s.likes, s.comments, s.shares, s.taken_at
      from post_metric_snapshots s
     where s.brand_id = p_brand
       and (p_platform is null or s.platform = p_platform)
     order by s.video_id, s.taken_at desc
  ),
  scoped as (
    select l.video_id, l.connection_id, l.platform, l.post_target_id, l.posted_at,
           l.title, l.description, l.cover_url, l.share_url, l.duration_s,
           l.views, l.likes, l.comments, l.shares,
           p.id as post_id, p.format, p.pillar_id, cp.name as pillar,
           p.plan_id, pl.title as campaign, p.hook
      from latest l
      left join post_targets t     on t.id = l.post_target_id
      left join posts p            on p.id = t.post_id
      left join content_pillars cp on cp.id = p.pillar_id
      left join content_plans pl   on pl.id = p.plan_id
     where (p_format is null or p.format = p_format)
       and (p_pillar is null or p.pillar_id = p_pillar)
       and (p_plan   is null or p.plan_id = p_plan)
  ),
  periods as (
    select * from (values ('current', p_from, p_to), ('previous', v_prev_from, v_prev_to))
      as x(period, start_on, end_on)
  ),
  bounds as (
    select per.period, i as idx,
           per.start_on + i * v_step as b_start,
           least(per.start_on + (i + 1) * v_step - 1, per.end_on) as b_end
      from periods per
      cross join generate_series(0, v_buckets - 1) as i
  ),
  edges as (
    select d, (d::timestamp at time zone v_tz) as ts
      from (select b_start as d from bounds union select b_end + 1 from bounds) e
  ),
  video_edges as (
    select e.d, v.video_id,
           (v.posted_at is not null and v.posted_at >= e.ts) as not_yet_posted,
           r.views, r.likes, r.comments, r.shares
      from edges e
      cross join scoped v
      left join lateral (
        select s.views, s.likes, s.comments, s.shares
          from post_metric_snapshots s
         where s.brand_id = p_brand
           and s.video_id = v.video_id
           and s.taken_at < e.ts
         order by s.taken_at desc
         limit 1
      ) r on true
  ),
  video_values as (
    select d, video_id,
           case when not_yet_posted then 0::bigint else views    end as views,
           case when not_yet_posted then 0::bigint else likes    end as likes,
           case when not_yet_posted then 0::bigint else comments end as comments,
           case when not_yet_posted then 0::bigint else shares   end as shares
      from video_edges
  ),
  accounts as (
    select distinct a.connection_id
      from account_metric_snapshots a
     where a.brand_id = p_brand
       and (p_platform is null or a.platform = p_platform)
  ),
  account_values as (
    select e.d, c.connection_id, r.followers
      from edges e
      cross join accounts c
      left join lateral (
        select a.followers
          from account_metric_snapshots a
         where a.connection_id = c.connection_id
           and a.brand_id = p_brand
           and a.followers is not null
           and a.taken_at < e.ts
         order by a.taken_at desc
         limit 1
      ) r on true
  ),
  gains as (
    select sp.period, sp.idx, sp.b_start, sp.b_end,
           m.views, m.likes, m.comments, m.shares,
           coalesce(m.videos, 0)  as videos,
           coalesce(m.unknown, 0) as unknown,
           f.followers,
           coalesce(f.accounts, 0) as accounts,
           coalesce(f.unknown, 0)  as followers_unknown
      from (
        select period, idx, b_start, b_end from bounds
        union all
        -- The whole period, as idx -1, so totals use the same arithmetic.
        select period, -1, start_on, end_on from periods
      ) sp
      left join lateral (
        select sum(e2.views    - e1.views)    filter (where e1.views    is not null and e2.views    is not null)::bigint as views,
               sum(e2.likes    - e1.likes)    filter (where e1.likes    is not null and e2.likes    is not null)::bigint as likes,
               sum(e2.comments - e1.comments) filter (where e1.comments is not null and e2.comments is not null)::bigint as comments,
               sum(e2.shares   - e1.shares)   filter (where e1.shares   is not null and e2.shares   is not null)::bigint as shares,
               count(*)::int as videos,
               count(*) filter (where e1.views is null or e2.views is null)::int as unknown
          from video_values e1
          join video_values e2 on e2.video_id = e1.video_id and e2.d = sp.b_end + 1
         where e1.d = sp.b_start
      ) m on true
      left join lateral (
        select sum(a2.followers - a1.followers)
                 filter (where a1.followers is not null and a2.followers is not null)::bigint as followers,
               count(*)::int as accounts,
               count(*) filter (where a1.followers is null or a2.followers is null)::int as unknown
          from account_values a1
          join account_values a2 on a2.connection_id = a1.connection_id and a2.d = sp.b_end + 1
         where a1.d = sp.b_start
      ) f on true
  ),
  stats as (
    select count(*)::int as videos,
           percentile_cont(0.5) within group (order by views) as median_views
      from scoped
  ),
  in_range as (
    select * from scoped
     where posted_at >= (p_from::timestamp at time zone v_tz)
       and posted_at <  ((p_to + 1)::timestamp at time zone v_tz)
  ),
  top_source as (
    select * from in_range
    union all
    select * from scoped where not exists (select 1 from in_range)
  ),
  timed as (
    select extract(isodow from (posted_at at time zone v_tz))::int as weekday,
           (extract(hour from (posted_at at time zone v_tz))::int / 3) * 3 as block,
           views
      from scoped
     where posted_at is not null
  ),
  timed_stats as (
    select count(*)::int as n, percentile_cont(0.5) within group (order by views) as med from timed
  ),
  hour_blocks as (
    select block as slot, count(*)::int as posts,
           percentile_cont(0.5) within group (order by views) as median_views
      from timed group by block
  ),
  day_groups as (
    select weekday as slot, count(*)::int as posts,
           percentile_cont(0.5) within group (order by views) as median_views
      from timed group by weekday
  ),
  best_hour as (
    select h.slot, h.posts, h.median_views,
           case when ts.med > 0 then h.median_views / ts.med - 1 end as lift, ts.n as total
      from hour_blocks h cross join timed_stats ts
     where h.posts >= 3 and ts.n >= 8 and ts.med > 0
     order by h.median_views desc
     limit 1
  ),
  best_day as (
    select d.slot, d.posts, d.median_views,
           case when ts.med > 0 then d.median_views / ts.med - 1 end as lift, ts.n as total
      from day_groups d cross join timed_stats ts
     where d.posts >= 3 and ts.n >= 8 and ts.med > 0
     order by d.median_views desc
     limit 1
  ),
  breakdowns as (
    select 'platform' as dimension, platform as label, count(*)::int as posts,
           percentile_cont(0.5) within group (order by views) as median_views,
           percentile_cont(0.5) within group (order by (likes + comments + shares)::numeric / nullif(views, 0)) as median_engagement
      from scoped group by platform
    union all
    select 'format', format, count(*)::int,
           percentile_cont(0.5) within group (order by views),
           percentile_cont(0.5) within group (order by (likes + comments + shares)::numeric / nullif(views, 0))
      from scoped where format is not null group by format
    union all
    select 'pillar', pillar, count(*)::int,
           percentile_cont(0.5) within group (order by views),
           percentile_cont(0.5) within group (order by (likes + comments + shares)::numeric / nullif(views, 0))
      from scoped where pillar is not null group by pillar
    union all
    select 'campaign', campaign, count(*)::int,
           percentile_cont(0.5) within group (order by views),
           percentile_cont(0.5) within group (order by (likes + comments + shares)::numeric / nullif(views, 0))
      from scoped where campaign is not null group by campaign
  ),
  connected as (
    select distinct pc.platform::text as platform
      from platform_connections pc
     where pc.brand_id = p_brand and pc.status = 'active'
  ),
  support as (
    select key, value
      from connected c, jsonb_each_text(platform_metric_support(c.platform))
     where p_platform is null or c.platform = p_platform
  ),
  availability as (
    -- A metric is actual when any platform in scope gives it.
    select key,
           case when bool_or(value = 'actual') then 'actual'
                when bool_or(value = 'derived') then 'derived'
                else 'unavailable' end as status
      from support group by key
  )
  select jsonb_build_object(
    'status', case
                when not exists (select 1 from connected) then 'no_connection'
                when (select videos from stats) = 0 then 'no_videos'
                else 'ok' end,
    'timezone', v_tz,
    'range', jsonb_build_object(
      'from', p_from, 'to', p_to, 'prev_from', v_prev_from, 'prev_to', v_prev_to,
      'step', v_step,
      'grain', case v_step when 1 then 'day' when 7 then 'week' else 'month' end),
    'history_starts', (select _iso(min(taken_at)) from post_metric_snapshots where brand_id = p_brand),
    'platforms', coalesce((select jsonb_agg(platform order by platform) from connected), '[]'::jsonb),
    'availability', coalesce((select jsonb_object_agg(key, status) from availability), '{}'::jsonb),
    'filtered', v_filtered,
    'totals', jsonb_build_object(
      'current',  (select to_jsonb(g) - 'period' - 'idx' - 'b_start' - 'b_end' from gains g where g.period = 'current'  and g.idx = -1),
      'previous', (select to_jsonb(g) - 'period' - 'idx' - 'b_start' - 'b_end' from gains g where g.period = 'previous' and g.idx = -1)),
    'series', coalesce((
      select jsonb_agg(jsonb_build_object(
               'period', g.period, 'idx', g.idx, 'start', g.b_start, 'end', g.b_end,
               'views', g.views, 'likes', g.likes, 'comments', g.comments, 'shares', g.shares,
               'followers', g.followers, 'videos', g.videos, 'unknown', g.unknown,
               'accounts', g.accounts, 'followers_unknown', g.followers_unknown)
             order by g.period, g.idx)
        from gains g where g.idx >= 0), '[]'::jsonb),
    'videos', (select videos from stats),
    'median_views', (select median_views from stats),
    'top_scope', case when exists (select 1 from in_range) then 'posted_in_range' else 'all_time' end,
    'top', coalesce((
      select jsonb_agg(row_to_json(t)::jsonb order by t.views desc)
        from (
          select s.video_id, s.title, s.description, s.cover_url, s.share_url, s.platform,
                 _iso(s.posted_at) as posted_at, s.duration_s,
                 s.views, s.likes, s.comments, s.shares,
                 case when s.views > 0 then round((s.likes + s.comments + s.shares)::numeric / s.views, 4) end as engagement_rate,
                 case when st.median_views > 0 then round((s.views / st.median_views)::numeric, 2) end as relative,
                 s.post_id, s.format, s.pillar, s.campaign, s.hook,
                 (s.post_target_id is not null) as from_autocast
            from top_source s cross join stats st
           order by s.views desc
           limit 25
        ) t), '[]'::jsonb),
    'best_time', jsonb_build_object(
      'videos', (select n from timed_stats),
      'minimum', 8,
      'overall_median', (select med from timed_stats),
      'hours', coalesce((select jsonb_agg(to_jsonb(h) order by h.slot) from hour_blocks h), '[]'::jsonb),
      'days',  coalesce((select jsonb_agg(to_jsonb(d) order by d.slot) from day_groups d), '[]'::jsonb),
      'best_hours', (
        select jsonb_build_object('slot', slot, 'posts', posts, 'median_views', median_views, 'lift', lift,
                 'confidence', case when total >= 30 and posts >= 8 and lift >= 0.3 then 'high'
                                    when total >= 15 and posts >= 5 and lift >= 0.2 then 'medium'
                                    when lift >= 0.15 then 'low' end)
          from best_hour where lift >= 0.15),
      'best_day', (
        select jsonb_build_object('slot', slot, 'posts', posts, 'median_views', median_views, 'lift', lift,
                 'confidence', case when total >= 30 and posts >= 8 and lift >= 0.3 then 'high'
                                    when total >= 15 and posts >= 5 and lift >= 0.2 then 'medium'
                                    when lift >= 0.15 then 'low' end)
          from best_day where lift >= 0.15)),
    'breakdowns', coalesce((select jsonb_agg(to_jsonb(b)) from breakdowns b), '[]'::jsonb),
    'filters', jsonb_build_object(
      'formats', coalesce((select jsonb_agg(distinct p.format) from posts p where p.brand_id = p_brand), '[]'::jsonb),
      'pillars', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name)
                             from content_pillars c where c.brand_id = p_brand), '[]'::jsonb),
      'campaigns', coalesce((select jsonb_agg(jsonb_build_object('id', pl.id, 'name', pl.title) order by pl.created_at desc)
                               from content_plans pl where pl.brand_id = p_brand and pl.status <> 'archived'), '[]'::jsonb)),
    'campaigns', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pl.id, 'title', pl.title, 'status', pl.status, 'starts_on', pl.starts_on, 'days', pl.days,
               'posts', (select count(*) from posts p where p.plan_id = pl.id),
               'published', (select count(*) from post_targets t join posts p on p.id = t.post_id
                              where p.plan_id = pl.id and t.state = 'published'),
               'videos', (select count(*) from scoped s where s.plan_id = pl.id),
               'views', (select sum(s.views) from scoped s where s.plan_id = pl.id),
               'likes', (select sum(s.likes) from scoped s where s.plan_id = pl.id),
               'comments', (select sum(s.comments) from scoped s where s.plan_id = pl.id),
               'shares', (select sum(s.shares) from scoped s where s.plan_id = pl.id))
             order by pl.created_at desc)
        from content_plans pl
       where pl.brand_id = p_brand and pl.status <> 'archived'), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $$;

revoke execute on function analytics_report(uuid, date, date, text, text, uuid, uuid) from anon, public;
grant  execute on function analytics_report(uuid, date, date, text, text, uuid, uuid) to authenticated;

-- ------------------------------------------------------------ one post

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
           (l.likes + l.comments + l.shares)::numeric / nullif(l.views, 0) as engagement
      from latest l
      left join post_targets t     on t.id = l.post_target_id
      left join posts p            on p.id = t.post_id
      left join content_pillars cp on cp.id = p.pillar_id
  ),
  me as (select * from enriched where video_id = p_video),
  groups as (
    select 'account' as scope, 'All your videos' as label, count(*)::int as posts,
           percentile_cont(0.5) within group (order by e.views) as median_views,
           percentile_cont(0.5) within group (order by e.engagement) as median_engagement
      from enriched e where e.video_id <> p_video
    union all
    select 'format', 'Same format (' || m.format || ')', count(e.*)::int,
           percentile_cont(0.5) within group (order by e.views),
           percentile_cont(0.5) within group (order by e.engagement)
      from me m join enriched e on e.format = m.format and e.video_id <> p_video
     where m.format is not null group by m.format
    union all
    select 'pillar', 'Same theme (' || m.pillar || ')', count(e.*)::int,
           percentile_cont(0.5) within group (order by e.views),
           percentile_cont(0.5) within group (order by e.engagement)
      from me m join enriched e on e.pillar = m.pillar and e.video_id <> p_video
     where m.pillar is not null group by m.pillar
    union all
    select 'platform', 'Same platform', count(e.*)::int,
           percentile_cont(0.5) within group (order by e.views),
           percentile_cont(0.5) within group (order by e.engagement)
      from me m join enriched e on e.platform = m.platform and e.video_id <> p_video
     where (select count(distinct platform) from enriched) > 1
     group by m.platform
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
    -- Only groups big enough to say something: three other videos at least.
    'comparisons', coalesce((
      select jsonb_agg(to_jsonb(g)) from groups g where g.posts >= 3), '[]'::jsonb)
  ) end into v_out;

  return v_out;
end $$;

revoke execute on function post_analytics(uuid, text) from anon, public;
grant  execute on function post_analytics(uuid, text) to authenticated;

-- ------------------------------------------------------------ autopilot

create or replace function autopilot_report(p_brand uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tz    text;
  v_start timestamptz;
  v_end   timestamptz;
  v_out   jsonb;
begin
  select coalesce(nullif(b.timezone, ''), 'UTC') into v_tz
    from brands b
   where b.id = p_brand and b.user_id = (select auth.uid());
  if v_tz is null then
    return null;
  end if;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;

  with
  jobs as (
    select * from generation_jobs j
     where j.brand_id = p_brand and j.created_at >= v_start and j.created_at < v_end
  ),
  latest as (
    select distinct on (s.video_id) s.video_id, s.post_target_id, s.views
      from post_metric_snapshots s
     where s.brand_id = p_brand
     order by s.video_id, s.taken_at desc
  ),
  sourced as (
    select l.views,
           (select a.source::text from post_assets pa join media_assets a on a.id = pa.asset_id
             where pa.post_target_id = l.post_target_id order by pa.ordinal limit 1) as source
      from latest l
     where l.post_target_id is not null
  ),
  compare as (
    select case when source = 'generated' then 'autopilot' else 'manual' end as side,
           count(*)::int as posts,
           percentile_cont(0.5) within group (order by views) as median_views
      from sourced where source is not null
     group by 1
  )
  select jsonb_build_object(
    'is_on', coalesce((select s.is_on from brand_settings s where s.brand_id = p_brand), false),
    'jobs', (select count(*) from jobs),
    'succeeded', (select count(*) from jobs where status = 'succeeded'),
    'failed', (select count(*) from jobs where status in ('failed', 'rejected_nsfw')),
    'cancelled', (select count(*) from jobs where status = 'cancelled'),
    'in_progress', (select count(*) from jobs where status in ('queued', 'submitted', 'running')),
    'avg_generation_seconds', (
      select round(avg(extract(epoch from (finished_at - coalesce(submitted_at, created_at))))::numeric)
        from jobs where status = 'succeeded' and finished_at is not null),
    -- Only what providers actually reported. A job with no stated cost is not
    -- a free job, so unreported jobs are counted separately, never as zero.
    'cost_cents', (select sum(cost_cents) from jobs where cost_cents > 0),
    'cost_reported_jobs', (select count(*) from jobs where cost_cents > 0),
    'failure_reasons', coalesce((
      select jsonb_agg(jsonb_build_object('code', code, 'count', n) order by n desc)
        from (select coalesce(failure_code, 'unknown') as code, count(*)::int as n
                from jobs where status in ('failed', 'rejected_nsfw') group by 1 order by 2 desc limit 5) f), '[]'::jsonb),
    'planned', (select count(*) from posts p
                 where p.brand_id = p_brand and p.scheduled_for >= v_start and p.scheduled_for < v_end),
    'published', (select count(*) from post_targets t join posts p on p.id = t.post_id
                   where p.brand_id = p_brand and t.published_at >= v_start and t.published_at < v_end),
    'waiting_approval', (select count(*) from post_targets t join posts p on p.id = t.post_id
                          where p.brand_id = p_brand
                            and (t.state = 'needs_reapproval' or (t.state = 'pending' and t.consent_id is null))),
    'compare', coalesce((
      select jsonb_object_agg(side, jsonb_build_object('posts', posts, 'median_views', median_views))
        from compare), '{}'::jsonb)
  ) into v_out;

  return v_out;
end $$;

revoke execute on function autopilot_report(uuid, date, date) from anon, public;
grant  execute on function autopilot_report(uuid, date, date) to authenticated;

-- ------------------------------------------------------------ acting on advice

-- Apply writes the measured fact into brand_memory, which propose-plan and Chat
-- both read: the recommendation changes what gets written next, not a label.
-- Plan hands back the brief the app opens the plan writer with. Ignore is
-- remembered, so the learning job does not offer it again.
create or replace function act_on_recommendation(p_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r     recommendations;
  v_mem uuid;
begin
  select * into r from recommendations where id = p_id and user_id = (select auth.uid());
  if r.id is null then
    raise exception 'That recommendation is not yours or no longer exists.' using errcode = 'P0002';
  end if;

  if p_action = 'apply' then
    v_mem := r.memory_id;
    if v_mem is null and coalesce(r.action->>'fact', '') <> '' then
      insert into brand_memory (user_id, brand_id, fact, source, source_ref)
      values (r.user_id, r.brand_id, r.action->>'fact', 'metrics', r.id)
      returning id into v_mem;
    end if;
    update recommendations
       set status = 'applied', memory_id = v_mem, acted_at = now(), updated_at = now()
     where id = r.id;
  elsif p_action = 'plan' then
    update recommendations set status = 'planned', acted_at = now(), updated_at = now() where id = r.id;
  elsif p_action = 'ignore' then
    update recommendations set status = 'ignored', acted_at = now(), updated_at = now() where id = r.id;
  elsif p_action = 'reopen' then
    if r.memory_id is not null then
      delete from brand_memory where id = r.memory_id and user_id = r.user_id;
    end if;
    update recommendations
       set status = 'open', memory_id = null, acted_at = null, updated_at = now()
     where id = r.id;
  else
    raise exception 'Unknown action %', p_action using errcode = '22023';
  end if;

  return jsonb_build_object(
    'status', (select status from recommendations where id = r.id),
    'brief', r.action->>'brief');
end $$;

revoke execute on function act_on_recommendation(uuid, text) from anon, public;
grant  execute on function act_on_recommendation(uuid, text) to authenticated;

-- ------------------------------------------------------------ learning input

-- Every video's latest reading, with what Autocast knows about how it was made.
-- Service role only: the learning job reads it for any brand.
create or replace function learning_input(p_brand uuid)
returns table (
  video_id text, platform text, posted_at timestamptz, duration_s integer, description text,
  views bigint, likes bigint, comments bigint, shares bigint,
  hook text, format text, pillar text, source text, timezone text
)
language sql
stable
security definer
set search_path = public
as $$
  select l.video_id, l.platform, l.posted_at, l.duration_s,
         coalesce(nullif(l.description, ''), l.title),
         l.views, l.likes, l.comments, l.shares,
         p.hook, p.format, cp.name,
         (select a.source::text from post_assets pa join media_assets a on a.id = pa.asset_id
           where pa.post_target_id = l.post_target_id order by pa.ordinal limit 1),
         coalesce(nullif(b.timezone, ''), 'UTC')
    from (
      select distinct on (s.video_id) s.*
        from post_metric_snapshots s
       where s.brand_id = p_brand
       order by s.video_id, s.taken_at desc
    ) l
    join brands b on b.id = p_brand
    left join post_targets t     on t.id = l.post_target_id
    left join posts p            on p.id = t.post_id
    left join content_pillars cp on cp.id = p.pillar_id;
$$;

revoke execute on function learning_input(uuid) from anon, authenticated, public;
