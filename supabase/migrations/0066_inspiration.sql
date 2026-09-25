-- Ideas for the next video, from the videos this account already made.
--
-- Abel, 25 Sep 2026: "depending on the kind of videos the user makes, the
-- captions, the hashtags -- understand what videos he's making and give the
-- user inspirational videos to post, like VidIQ."
--
-- The feed is NOT a trend scrape. Autocast can read one thing nobody else can:
-- this account's own numbers, which `learning_input` already returns and
-- `_shared/learning.ts` already turns into findings. An idea here is a hook
-- plus the measured reason it is being suggested -- "your videos under 20
-- seconds get 2.4x the views" -- so the person can judge the suggestion
-- instead of taking it on faith.
--
-- `measured` is the column that keeps this honest. A brand-new account has no
-- numbers, and the feed still has to say something; those ideas come from the
-- pillars and the style the person chose, and are marked `measured = false` so
-- the app can say "a starting point" rather than implying an audience finding
-- that does not exist yet. See [[planner-invents-facts]]: the failure mode here
-- is announcing a fact the account has not earned.
create table if not exists inspiration_ideas (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  brand_id    uuid not null references brands on delete cascade,
  -- Stable across runs so a refresh updates an idea rather than duplicating
  -- it, and so "not interested" survives the next refresh.
  key         text not null,
  -- The first line of the video. What gets typed into the video page.
  hook        text not null,
  -- One sentence on what the video actually is, after the hook.
  angle       text not null,
  -- Why this is being suggested, in the account's own numbers. Never empty:
  -- an idea that cannot say why is dropped before it is written here.
  because     text not null,
  -- The measured evidence behind `because`, so the sentence can be checked
  -- rather than believed: {insight_key, lift, sample_size, video_id}.
  evidence    jsonb not null default '{}'::jsonb,
  -- false when this came from the brand's stated pillars rather than from
  -- posts with numbers on them. The app says so on the card.
  measured    boolean not null default false,
  seconds     integer,
  format      text,
  hashtags    text[] not null default '{}',
  -- 'new' until it is acted on. 'made' when a video was started from it,
  -- 'hidden' when it was dismissed -- both keep it out of the feed, and
  -- 'hidden' keeps it out of the next refresh as well.
  status      text not null default 'new' check (status in ('new','made','hidden')),
  computed_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  unique (brand_id, key)
);

create index if not exists inspiration_brand_status
  on inspiration_ideas (brand_id, status, computed_at desc);

alter table inspiration_ideas enable row level security;

-- Read by the owner. Written only by the function that computes them, for the
-- same reason insights are: an idea the client could write is an idea that
-- could carry an invented reason and still look measured.
drop policy if exists inspiration_read on inspiration_ideas;
create policy inspiration_read on inspiration_ideas for select to authenticated
  using ((select auth.uid()) = user_id);

grant select on inspiration_ideas to authenticated;

-- Marking one used or dismissed is the owner's to do, and is the only write
-- they get: the status, nothing else. Security definer so the table can stay
-- closed while this one column moves.
create or replace function set_inspiration_status(p_idea uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := (select auth.uid());
begin
  if v_user is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if p_status not in ('new', 'made', 'hidden') then
    raise exception 'unknown status %', p_status using errcode = '22023';
  end if;
  update inspiration_ideas
     set status = p_status
   where id = p_idea
     and user_id = v_user;
  if not found then
    raise exception 'that idea is not yours' using errcode = '42501';
  end if;
end;
$$;

revoke all on function set_inspiration_status(uuid, text) from public;
grant execute on function set_inspiration_status(uuid, text) to authenticated;
