-- 0054: recommend a posting time sooner.
--
-- The bar was eight videos with numbers before Autocast would name a time,
-- and three videos in a block before that block counted. Abel, 22 Sep 2026:
-- "why does our app asks for 10 posts? its so much brother." It is: somebody
-- posting twice a week waits a month to see anything.
--
-- Three videos, two per block. The confidence label is unchanged and still
-- says low until the sample is real, so the number arrives earlier and says
-- plainly how much to trust it.
--
-- The body below is the live function (0040) with those three numbers moved.

CREATE OR REPLACE FUNCTION public.analytics_report(p_brand uuid, p_from date, p_to date, p_platform text DEFAULT NULL::text, p_format text DEFAULT NULL::text, p_pillar uuid DEFAULT NULL::uuid, p_plan uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  video_values as (
    select e.d, e.ts, v.video_id,
           case when v.posted_at is not null and v.posted_at >= e.ts then 0::bigint else r.views    end as views,
           case when v.posted_at is not null and v.posted_at >= e.ts then 0::bigint else r.likes    end as likes,
           case when v.posted_at is not null and v.posted_at >= e.ts then 0::bigint else r.comments end as comments,
           case when v.posted_at is not null and v.posted_at >= e.ts then 0::bigint else r.shares   end as shares,
           a.views as after_views, a.likes as after_likes, a.comments as after_comments,
           a.shares as after_shares, a.taken_at as after_at
      from edges e
      cross join scoped v
      left join lateral (
        select s.views, s.likes, s.comments, s.shares
          from post_metric_snapshots s
         where s.brand_id = p_brand and s.video_id = v.video_id and s.taken_at < e.ts
         order by s.taken_at desc
         limit 1
      ) r on true
      left join lateral (
        select s.views, s.likes, s.comments, s.shares, s.taken_at
          from post_metric_snapshots s
         where s.brand_id = p_brand and s.video_id = v.video_id and s.taken_at >= e.ts
         order by s.taken_at asc
         limit 1
      ) a on true
  ),
  accounts as (
    select distinct a.connection_id
      from account_metric_snapshots a
     where a.brand_id = p_brand
       and (p_platform is null or a.platform = p_platform)
  ),
  account_values as (
    select e.d, e.ts, c.connection_id, r.followers,
           a.followers as after_followers, a.taken_at as after_at
      from edges e
      cross join accounts c
      left join lateral (
        select x.followers
          from account_metric_snapshots x
         where x.connection_id = c.connection_id and x.brand_id = p_brand
           and x.followers is not null and x.taken_at < e.ts
         order by x.taken_at desc
         limit 1
      ) r on true
      left join lateral (
        select x.followers, x.taken_at
          from account_metric_snapshots x
         where x.connection_id = c.connection_id and x.brand_id = p_brand
           and x.followers is not null and x.taken_at >= e.ts
         order by x.taken_at asc
         limit 1
      ) a on true
  ),
  -- Trend buckets: strict. No reading before the bucket = unknown.
  gains as (
    select b.period, b.idx, b.b_start, b.b_end,
           m.views, m.likes, m.comments, m.shares,
           coalesce(m.videos, 0)  as videos,
           coalesce(m.unknown, 0) as unknown,
           f.followers,
           coalesce(f.accounts, 0) as accounts,
           coalesce(f.unknown, 0)  as followers_unknown
      from bounds b
      left join lateral (
        select sum(e2.views    - e1.views)    filter (where e1.views    is not null and e2.views    is not null)::bigint as views,
               sum(e2.likes    - e1.likes)    filter (where e1.likes    is not null and e2.likes    is not null)::bigint as likes,
               sum(e2.comments - e1.comments) filter (where e1.comments is not null and e2.comments is not null)::bigint as comments,
               sum(e2.shares   - e1.shares)   filter (where e1.shares   is not null and e2.shares   is not null)::bigint as shares,
               count(*)::int as videos,
               count(*) filter (where e1.views is null or e2.views is null)::int as unknown
          from video_values e1
          join video_values e2 on e2.video_id = e1.video_id and e2.d = b.b_end + 1
         where e1.d = b.b_start
      ) m on true
      left join lateral (
        select sum(a2.followers - a1.followers)
                 filter (where a1.followers is not null and a2.followers is not null)::bigint as followers,
               count(*)::int as accounts,
               count(*) filter (where a1.followers is null or a2.followers is null)::int as unknown
          from account_values a1
          join account_values a2 on a2.connection_id = a1.connection_id and a2.d = b.b_end + 1
         where a1.d = b.b_start
      ) f on true
  ),
  -- Period totals: a missing start is replaced by the first reading inside
  -- the period, and counted as partial.
  totals as (
    select per.period,
           m.views, m.likes, m.comments, m.shares,
           coalesce(m.videos, 0) as videos,
           coalesce(m.unknown, 0) as unknown,
           coalesce(m.partial, 0) as partial_videos,
           m.counted_from,
           f.followers,
           coalesce(f.accounts, 0) as accounts,
           coalesce(f.unknown, 0) as followers_unknown,
           coalesce(f.partial, 0) as followers_partial,
           f.counted_from as followers_counted_from
      from periods per
      left join lateral (
        select sum(x.v_end - x.v_start) filter (where x.ok)::bigint as views,
               sum(x.l_end - x.l_start) filter (where x.ok)::bigint as likes,
               sum(x.c_end - x.c_start) filter (where x.ok)::bigint as comments,
               sum(x.s_end - x.s_start) filter (where x.ok)::bigint as shares,
               count(*)::int as videos,
               count(*) filter (where not x.ok)::int as unknown,
               count(*) filter (where x.ok and x.fallback)::int as partial,
               min(x.from_at) filter (where x.ok and x.fallback) as counted_from
          from (
            select e2.views as v_end, e2.likes as l_end, e2.comments as c_end, e2.shares as s_end,
                   coalesce(e1.views, e1.after_views)       as v_start,
                   coalesce(e1.likes, e1.after_likes)       as l_start,
                   coalesce(e1.comments, e1.after_comments) as c_start,
                   coalesce(e1.shares, e1.after_shares)     as s_start,
                   (e1.views is null) as fallback,
                   e1.after_at as from_at,
                   (e2.views is not null
                     and (e1.views is not null
                          or (e1.after_views is not null and e1.after_at < e2.ts))) as ok
              from video_values e1
              join video_values e2 on e2.video_id = e1.video_id and e2.d = per.end_on + 1
             where e1.d = per.start_on
          ) x
      ) m on true
      left join lateral (
        select sum(x.f_end - x.f_start) filter (where x.ok)::bigint as followers,
               count(*)::int as accounts,
               count(*) filter (where not x.ok)::int as unknown,
               count(*) filter (where x.ok and x.fallback)::int as partial,
               min(x.from_at) filter (where x.ok and x.fallback) as counted_from
          from (
            select a2.followers as f_end,
                   coalesce(a1.followers, a1.after_followers) as f_start,
                   (a1.followers is null) as fallback,
                   a1.after_at as from_at,
                   (a2.followers is not null
                     and (a1.followers is not null
                          or (a1.after_followers is not null and a1.after_at < a2.ts))) as ok
              from account_values a1
              join account_values a2 on a2.connection_id = a1.connection_id and a2.d = per.end_on + 1
             where a1.d = per.start_on
          ) x
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
     where h.posts >= 2 and ts.n >= 3 and ts.med > 0
     order by h.median_views desc
     limit 1
  ),
  best_day as (
    select d.slot, d.posts, d.median_views,
           case when ts.med > 0 then d.median_views / ts.med - 1 end as lift, ts.n as total
      from day_groups d cross join timed_stats ts
     where d.posts >= 2 and ts.n >= 3 and ts.med > 0
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
    select key,
           case when bool_or(value = 'actual') then 'actual'
                when bool_or(value = 'derived') then 'derived'
                else 'unavailable' end as status
      from support group by key
  ),
  latest_followers as (
    select distinct on (a.connection_id) a.followers
      from account_metric_snapshots a
     where a.brand_id = p_brand and a.followers is not null
       and (p_platform is null or a.platform = p_platform)
     order by a.connection_id, a.taken_at desc
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
    'followers_total', (select sum(followers) from latest_followers),
    'totals', jsonb_build_object(
      'current', (
        select jsonb_build_object(
                 'views', t.views, 'likes', t.likes, 'comments', t.comments, 'shares', t.shares,
                 'videos', t.videos, 'unknown', t.unknown,
                 'partial_videos', t.partial_videos, 'counted_from', _iso(t.counted_from),
                 'followers', t.followers, 'accounts', t.accounts,
                 'followers_unknown', t.followers_unknown, 'followers_partial', t.followers_partial,
                 'followers_counted_from', _iso(t.followers_counted_from))
          from totals t where t.period = 'current'),
      'previous', (
        select jsonb_build_object(
                 'views', t.views, 'likes', t.likes, 'comments', t.comments, 'shares', t.shares,
                 'videos', t.videos, 'unknown', t.unknown,
                 'partial_videos', t.partial_videos, 'counted_from', _iso(t.counted_from),
                 'followers', t.followers, 'accounts', t.accounts,
                 'followers_unknown', t.followers_unknown, 'followers_partial', t.followers_partial,
                 'followers_counted_from', _iso(t.followers_counted_from))
          from totals t where t.period = 'previous')),
    'series', coalesce((
      select jsonb_agg(jsonb_build_object(
               'period', g.period, 'idx', g.idx, 'start', g.b_start, 'end', g.b_end,
               'views', g.views, 'likes', g.likes, 'comments', g.comments, 'shares', g.shares,
               'followers', g.followers, 'videos', g.videos, 'unknown', g.unknown,
               'accounts', g.accounts, 'followers_unknown', g.followers_unknown)
             order by g.period, g.idx)
        from gains g), '[]'::jsonb),
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
      'minimum', 3,
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
end $function$
;
