-- Numbers over time, not just the latest ones.
--
-- `fetch-metrics` wrote each video's figures onto `post_targets.metrics` and
-- overwrote them the next time, and the follower count was returned to the
-- phone and never kept at all. So the app could say what a video has now, and
-- nothing about whether anything is growing -- which is the only question the
-- Analytics tab exists to answer, and the one the learning loop will need.
--
-- Two append-only tables, one row per reading. A reading happens when somebody
-- opens Analytics and every six hours on its own (the cron below), so a chart
-- has points even for an account nobody has looked at this week.

create table if not exists account_metric_snapshots (
  id            bigint generated always as identity primary key,
  user_id       uuid not null references auth.users on delete cascade,
  brand_id      uuid not null references brands on delete cascade,
  connection_id uuid not null references platform_connections on delete cascade,
  taken_at      timestamptz not null default now(),
  followers     bigint,
  likes         bigint,
  video_count   bigint
);

create index if not exists account_metric_snapshots_brand_idx
  on account_metric_snapshots (brand_id, taken_at desc);

-- Keyed by the platform's own video id rather than by our post, because most
-- videos on an account were not posted by Autocast and still belong on the
-- chart. `post_target_id` is filled when we did post it.
create table if not exists post_metric_snapshots (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references auth.users on delete cascade,
  brand_id       uuid not null references brands on delete cascade,
  connection_id  uuid not null references platform_connections on delete cascade,
  video_id       text not null,
  post_target_id uuid references post_targets on delete set null,
  title          text not null default '',
  posted_at      timestamptz,
  taken_at       timestamptz not null default now(),
  views          bigint not null default 0,
  likes          bigint not null default 0,
  comments       bigint not null default 0,
  shares         bigint not null default 0
);

create index if not exists post_metric_snapshots_brand_idx
  on post_metric_snapshots (brand_id, taken_at desc);
create index if not exists post_metric_snapshots_video_idx
  on post_metric_snapshots (connection_id, video_id, taken_at desc);

alter table account_metric_snapshots enable row level security;
alter table post_metric_snapshots    enable row level security;

-- Readable by the owner, written only by the function. A figure the client
-- could write is a figure the learning loop would trust.
drop policy if exists account_metric_snapshots_read on account_metric_snapshots;
create policy account_metric_snapshots_read on account_metric_snapshots for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists post_metric_snapshots_read on post_metric_snapshots;
create policy post_metric_snapshots_read on post_metric_snapshots for select to authenticated
  using ((select auth.uid()) = user_id);

grant select on account_metric_snapshots to authenticated;
grant select on post_metric_snapshots    to authenticated;

-- ------------------------------------------------------------ the six-hour loop

alter table private.scheduler_config
  add column if not exists metrics_url text,
  add column if not exists metrics_last_fired_at timestamptz;

-- Same host as the poller, so the address is derived rather than typed in a
-- second time and got wrong.
update private.scheduler_config
   set metrics_url = replace(poll_url, 'poll-generations', 'fetch-metrics')
 where id and metrics_url is null and poll_url is not null;

create or replace function tick_metrics()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare cfg private.scheduler_config;
begin
  select * into cfg from private.scheduler_config where id;

  if cfg is null or not cfg.enabled or cfg.metrics_url is null then
    return;
  end if;

  -- net.http_post, not extensions.net_http_post -- see 0008.
  perform net.http_post(
    url     := cfg.metrics_url,
    body    := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'x-cron-secret', cfg.cron_secret
    ),
    timeout_milliseconds := 60000
  );

  update private.scheduler_config set metrics_last_fired_at = now() where id;
end $$;

revoke execute on function tick_metrics() from anon, authenticated, public;

select cron.unschedule('fetch-metrics') where exists (
  select 1 from cron.job where jobname = 'fetch-metrics');

select cron.schedule('fetch-metrics', '17 */6 * * *', $job$select tick_metrics()$job$);

-- ------------------------------------------------------------ what the tab reads

-- One call for the whole tab: followers by day, total views by day, and each
-- video's latest numbers. A day's value is the last reading taken that day, so
-- opening the tab ten times does not count ten times.
create or replace function analytics_for(p_brand uuid, p_days int default 30)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with owned as (
    select id from brands where id = p_brand and user_id = (select auth.uid())
  ),
  account as (
    select distinct on (date_trunc('day', taken_at))
           date_trunc('day', taken_at) as day, followers
      from account_metric_snapshots
     where brand_id in (select id from owned)
       and followers is not null
       and taken_at > now() - make_interval(days => p_days)
     order by date_trunc('day', taken_at), taken_at desc
  ),
  per_video_day as (
    select distinct on (video_id, date_trunc('day', taken_at))
           video_id, date_trunc('day', taken_at) as day, views
      from post_metric_snapshots
     where brand_id in (select id from owned)
       and taken_at > now() - make_interval(days => p_days)
     order by video_id, date_trunc('day', taken_at), taken_at desc
  ),
  daily_views as (
    select day, sum(views)::bigint as views from per_video_day group by day
  ),
  latest_video as (
    select distinct on (video_id)
           video_id, title, posted_at, views, likes, comments, shares
      from post_metric_snapshots
     where brand_id in (select id from owned)
     order by video_id, taken_at desc
  )
  select jsonb_build_object(
    'followers', coalesce((
      select jsonb_agg(jsonb_build_object('day', to_char(day, 'YYYY-MM-DD'), 'value', followers) order by day)
        from account), '[]'::jsonb),
    'views', coalesce((
      select jsonb_agg(jsonb_build_object('day', to_char(day, 'YYYY-MM-DD'), 'value', views) order by day)
        from daily_views), '[]'::jsonb),
    'videos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', video_id, 'title', title, 'posted_at', posted_at,
               'views', views, 'likes', likes, 'comments', comments, 'shares', shares)
             order by posted_at desc nulls last)
        from latest_video), '[]'::jsonb)
  );
$$;

revoke execute on function analytics_for(uuid, int) from anon, public;
grant  execute on function analytics_for(uuid, int) to authenticated;
