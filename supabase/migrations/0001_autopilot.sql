-- Autocast: the queue the planner writes to and the app reads from.
--
-- Every table is per-user and protected by RLS. The planner runs as an edge
-- function with the service role, so it bypasses these policies deliberately;
-- the app only ever holds an anon key plus a user session, and must never be
-- able to read another account's queue.

create extension if not exists "pgcrypto";

-- The order of these values is the pipeline order. Adding a stage means
-- adding it in the right position with ALTER TYPE ... BEFORE/AFTER.
create type post_status as enum (
  'planned',
  'scripted',
  'rendering',
  'scheduled',
  'posted',
  'failed'
);

create type platform as enum ('tiktok', 'reels', 'shorts');

-- What the autopilot is allowed to decide, per user. One row each.
create table autopilot_settings (
  user_id            uuid primary key references auth.users on delete cascade,
  is_on              boolean     not null default false,
  posts_per_day      smallint    not null default 2 check (posts_per_day between 1 and 6),
  platforms          platform[]  not null default '{tiktok}',
  tone               text        not null default '',
  -- When true a post stops at 'scheduled' until approved_at is set.
  requires_approval  boolean     not null default true,
  quiet_hours_start  smallint    not null default 22 check (quiet_hours_start between 0 and 23),
  quiet_hours_end    smallint    not null default 7  check (quiet_hours_end   between 0 and 23),
  updated_at         timestamptz not null default now()
);

-- The themes the planner works within. It will not plan outside an enabled one.
create table content_pillars (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid        not null references auth.users on delete cascade,
  name        text        not null,
  detail      text        not null default '',
  weight      smallint    not null default 1 check (weight > 0),
  is_enabled  boolean     not null default true,
  created_at  timestamptz not null default now()
);

create index content_pillars_user_idx on content_pillars (user_id) where is_enabled;

-- Linked publishing destinations. A disconnected account keeps its row so
-- posted history stays readable.
create table social_accounts (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid        not null references auth.users on delete cascade,
  platform         platform    not null,
  handle           text        not null,
  -- Refresh token, encrypted at rest by Supabase Vault. Never selected by the
  -- app -- only the edge function that publishes reads this column.
  refresh_token    text,
  connected_at     timestamptz not null default now(),
  disconnected_at  timestamptz,
  unique (user_id, platform, handle)
);

create table content_posts (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid        not null references auth.users on delete cascade,
  pillar_id       uuid        references content_pillars on delete set null,
  account_id      uuid        references social_accounts on delete set null,

  hook            text        not null,
  script          text        not null default '',
  caption         text        not null default '',
  hashtags        text[]      not null default '{}',

  platform        platform    not null,
  status          post_status not null default 'planned',
  -- Why the planner chose this. Not optional: a queue of items with no stated
  -- reason is the failure mode this whole product is trying to avoid.
  rationale       text        not null,

  scheduled_for   timestamptz,
  posted_at       timestamptz,
  approved_at     timestamptz,
  failure_reason  text,

  views           integer,
  likes           integer,

  created_at      timestamptz not null default now(),

  -- A post cannot claim to be published without a time, or carry a time
  -- without being published. Cheap to enforce here, awkward to debug later.
  constraint posted_has_time check (
    (status = 'posted') = (posted_at is not null)
  ),
  constraint failed_has_reason check (
    status <> 'failed' or failure_reason is not null
  )
);

-- The app's main read: this user's queue, newest-relevant first.
create index content_posts_user_date_idx
  on content_posts (user_id, coalesce(posted_at, scheduled_for, created_at) desc);

-- The publisher's main read: what is due now, across all users.
create index content_posts_due_idx
  on content_posts (scheduled_for)
  where status = 'scheduled';

alter table autopilot_settings enable row level security;
alter table content_pillars    enable row level security;
alter table social_accounts    enable row level security;
alter table content_posts      enable row level security;

create policy "own settings" on autopilot_settings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own pillars" on content_pillars
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own accounts" on social_accounts
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own posts" on content_posts
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
