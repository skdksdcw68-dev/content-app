-- Analytics laid out the way TikTok Studio lays it out, from what TikTok
-- actually shares with an app.
--
-- Abel sent Studio's Overview / Content / Followers screens as the reference
-- (15 Sep 2026). Studio can show viewers, profile views, gender, age,
-- locations, traffic sources and when followers are online, because it is
-- TikTok. The API gives another app none of those -- only each public video's
-- views, likes, comments and shares, and the account's follower count. So this
-- returns exactly those, by day, and nothing is shaped to look like the rest.
--
-- "Best time to post" is the one thing added, and it is honest about what it
-- is: not when followers are online (TikTok does not say), but how the brand's
-- own videos did by the hour and weekday they went out, in the brand's
-- timezone. With a handful of public videos it says little; the app shows it
-- only once there are enough.
--
-- Same signature as 0037, so `create or replace` works (the 42P13 trap is for
-- `returns table`; this returns jsonb). Every new key is additive: build 44
-- decodes the three keys it knows and ignores the rest.

create or replace function analytics_for(p_brand uuid, p_days int default 30)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with owned as (
    select id, coalesce(nullif(timezone, ''), 'UTC') as tz
      from brands
     where id = p_brand and user_id = (select auth.uid())
  ),
  -- One day more than asked, so the first day in range has a day before it
  -- to be compared against.
  account as (
    select distinct on (date_trunc('day', taken_at))
           date_trunc('day', taken_at) as day, followers
      from account_metric_snapshots
     where brand_id in (select id from owned)
       and followers is not null
       and taken_at > now() - make_interval(days => p_days + 1)
     order by date_trunc('day', taken_at), taken_at desc
  ),
  per_video_day as (
    select distinct on (video_id, date_trunc('day', taken_at))
           video_id, date_trunc('day', taken_at) as day, views, likes, comments, shares
      from post_metric_snapshots
     where brand_id in (select id from owned)
       and taken_at > now() - make_interval(days => p_days + 1)
     order by video_id, date_trunc('day', taken_at), taken_at desc
  ),
  daily as (
    select day,
           sum(views)::bigint    as views,
           sum(likes)::bigint    as likes,
           sum(comments)::bigint as comments,
           sum(shares)::bigint   as shares
      from per_video_day
     group by day
  ),
  latest_video as (
    select distinct on (video_id)
           video_id, title, posted_at, views, likes, comments, shares
      from post_metric_snapshots
     where brand_id in (select id from owned)
     order by video_id, taken_at desc
  ),
  timed as (
    select extract(hour   from (v.posted_at at time zone o.tz))::int as hour,
           extract(isodow from (v.posted_at at time zone o.tz))::int as weekday,
           v.views
      from latest_video v
     cross join owned o
     where v.posted_at is not null
  )
  select jsonb_build_object(
    'followers', coalesce((
      select jsonb_agg(jsonb_build_object('day', to_char(day, 'YYYY-MM-DD'), 'value', followers) order by day)
        from account), '[]'::jsonb),
    'views', coalesce((
      select jsonb_agg(jsonb_build_object('day', to_char(day, 'YYYY-MM-DD'), 'value', views) order by day)
        from daily), '[]'::jsonb),
    'likes', coalesce((
      select jsonb_agg(jsonb_build_object('day', to_char(day, 'YYYY-MM-DD'), 'value', likes) order by day)
        from daily), '[]'::jsonb),
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object('day', to_char(day, 'YYYY-MM-DD'), 'value', comments) order by day)
        from daily), '[]'::jsonb),
    'shares', coalesce((
      select jsonb_agg(jsonb_build_object('day', to_char(day, 'YYYY-MM-DD'), 'value', shares) order by day)
        from daily), '[]'::jsonb),
    'videos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', video_id, 'title', title, 'posted_at', posted_at,
               'views', views, 'likes', likes, 'comments', comments, 'shares', shares)
             order by posted_at desc nulls last)
        from latest_video), '[]'::jsonb),
    -- Average views by the hour (0-23) and ISO weekday (1 = Monday) the
    -- brand's videos went out, with how many videos each average is made of.
    'best_hours', coalesce((
      select jsonb_agg(jsonb_build_object('slot', hour, 'posts', n, 'avg_views', avg_views) order by hour)
        from (select hour, count(*)::int as n, round(avg(views))::bigint as avg_views
                from timed group by hour) h), '[]'::jsonb),
    'best_days', coalesce((
      select jsonb_agg(jsonb_build_object('slot', weekday, 'posts', n, 'avg_views', avg_views) order by weekday)
        from (select weekday, count(*)::int as n, round(avg(views))::bigint as avg_views
                from timed group by weekday) d), '[]'::jsonb)
  );
$$;

revoke execute on function analytics_for(uuid, int) from anon, public;
grant  execute on function analytics_for(uuid, int) to authenticated;
