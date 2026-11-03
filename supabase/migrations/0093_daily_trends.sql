-- "Trending today" on the Explore tab (Abel, 3 Nov 2026). Looked up on the web
-- once a day per country by the `trends` function and shared by everyone there,
-- so a hundred people opening Explore cost one search, not a hundred.

create table if not exists public.daily_trends (
  day        date not null,
  region     text not null,
  items      jsonb not null,
  created_at timestamptz not null default now(),
  primary key (day, region)
);

alter table public.daily_trends enable row level security;

drop policy if exists daily_trends_read on public.daily_trends;
create policy daily_trends_read on public.daily_trends for select to authenticated using (true);

revoke all on public.daily_trends from anon;
grant select on public.daily_trends to authenticated;
