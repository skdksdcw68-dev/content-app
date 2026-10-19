-- Which videos are still up.
--
-- Netro, 19 Oct 2026: "If a video is deleted, made private, or becomes
-- unavailable, the view count still displays, suggesting the video is still
-- active." TikTok's video.list returns PUBLIC videos only, so a deleted or
-- privated video simply stops appearing -- and every screen kept showing its
-- last snapshot as though nothing had happened.
--
-- fetch-metrics now writes down, for each account, every video it saw and when
-- one it had seen stopped being listed. Only a listing that came back whole
-- (no error, every page read) can say a video is missing; a partial one says
-- nothing. TikTok does not say which of the three it was, so neither do we:
-- deleted, private, or removed all read as "no longer public".

create table if not exists public.video_presence (
  connection_id uuid not null references platform_connections(id) on delete cascade,
  video_id      text not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  missing_since timestamptz,
  primary key (connection_id, video_id)
);
alter table public.video_presence enable row level security;

-- Everything already known was public when it was last seen.
insert into public.video_presence (connection_id, video_id, first_seen_at, last_seen_at)
select s.connection_id, s.video_id, min(s.taken_at), max(s.taken_at)
  from post_metric_snapshots s
 where s.connection_id is not null and s.video_id is not null
 group by s.connection_id, s.video_id
on conflict (connection_id, video_id) do nothing;

-- The ones this brand's accounts no longer list publicly.
create or replace function public.unavailable_videos(p_brand uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'video_id', p.video_id,
           'missing_since', p.missing_since
         ) order by p.missing_since desc), '[]'::jsonb)
    from video_presence p
    join platform_connections c on c.id = p.connection_id
   where c.brand_id = p_brand
     and c.user_id = (select auth.uid())
     and p.missing_since is not null;
$$;

revoke execute on function public.unavailable_videos(uuid) from anon, public;
grant  execute on function public.unavailable_videos(uuid) to authenticated;
