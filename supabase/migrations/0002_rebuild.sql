-- Autocast v2 -- the schema for an agent that plans, makes and publishes.
--
-- 0001 modelled a queue: one row per post, one platform per post, no media, no
-- consent, no jobs. This replaces it wholesale. Nothing in 0001 holds data --
-- the planner that would have written to it was never called -- so there is no
-- backfill, no dual-write and no compatibility window.
--
-- Three ideas run through everything below:
--
--   1. A post fans out. One idea goes to N accounts, each with its own caption,
--      its own consent and its own rate limit. That is `post_targets`, and it is
--      the single biggest correction to 0001.
--   2. Rights are a column, not a policy document. Every asset records how it was
--      obtained, and nothing publishes unless that answer is good.
--   3. The queue is a table. Work is claimed with FOR UPDATE SKIP LOCKED under a
--      lease, so a crashed worker releases its work instead of losing it.

-- On Supabase pgcrypto is installed into the "extensions" schema rather than
-- public, so gen_random_bytes has to be qualified. gen_random_uuid does not --
-- that one is core Postgres since 13 and has nothing to do with pgcrypto.
create extension if not exists "pgcrypto" with schema extensions;

-- ---------------------------------------------------------------- teardown

drop table if exists content_posts       cascade;
drop table if exists social_accounts     cascade;
drop table if exists content_pillars     cascade;
drop table if exists autopilot_settings  cascade;
drop type  if exists post_status         cascade;
drop type  if exists platform            cascade;

-- ------------------------------------------------------------------- enums

-- Values unchanged from 0001: Platform.rawValue in Swift is the wire format.
create type platform as enum ('tiktok', 'reels', 'shorts');

-- Declaration order IS pipeline order; `pipelineRank` in Swift depends on it.
-- Two stages are new since 0001: `sourcing` (media is being made) and
-- `needs_approval` (media exists that the person has not seen yet).
create type post_status as enum (
  'planned', 'scripted', 'sourcing', 'needs_approval',
  'scheduled', 'posted', 'failed'
);

create type plan_status   as enum ('draft','proposed','approved','active','paused','archived');
create type asset_kind    as enum ('image','video','audio');

-- How an asset was obtained. `derived` is a variant of another asset; a
-- `style_reference` is deliberately NOT in this list -- see `style_references`.
create type asset_source  as enum ('generated','stock','user_upload','platform_library','derived');
create type rights_status as enum ('cleared','pending','unclear','blocked');

create type job_kind as enum (
  'image_generate','video_generate','audio_generate',
  'asset_ingest','asset_normalize','metrics_fetch','token_refresh'
);

-- `rejected_nsfw` is terminal and distinct because retrying the same prompt is
-- guaranteed to fail the same way. Retrying it just spends the user's money.
create type job_status as enum (
  'queued','submitted','running','succeeded','failed','rejected_nsfw','cancelled'
);

create type publish_state as enum (
  'pending','claimed','uploading','submitted','processing',
  'published','failed','cancelled','needs_reapproval'
);

create type connection_status as enum ('active','expired','revoked','error');
create type approval_status   as enum ('pending','approved','rejected','expired','superseded');
create type privacy_level     as enum (
  'PUBLIC_TO_EVERYONE','MUTUAL_FOLLOW_FRIENDS','FOLLOWER_OF_CREATOR','SELF_ONLY'
);
create type agent_run_status  as enum ('queued','running','waiting_on_user','succeeded','failed','cancelled');
create type message_role      as enum ('user','assistant','tool','system');

-- ----------------------------------------------------------------- tenancy

create table profiles (
  user_id      uuid primary key references auth.users on delete cascade,
  display_name text not null default '',
  created_at   timestamptz not null default now()
);

-- A person can run more than one account -- "my app Remi", "my consultancy" --
-- and they do not share a voice, a schedule or a connected account.
create table brands (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  name        text not null,
  audience    text not null default '',
  niche       text not null default '',
  -- IANA zone. ALL slot arithmetic happens in this, never in UTC and never in
  -- device local time. 0001 got this wrong in two directions at once: the
  -- planner read quiet hours as UTC while the app read them as device local,
  -- so the same setting gave two answers.
  timezone    text not null default 'UTC',
  uses_memory boolean not null default true,
  created_at  timestamptz not null default now(),
  archived_at timestamptz
);
create index brands_user_idx on brands (user_id) where archived_at is null;

-- What the planner has worked out and now applies without being told again.
-- Shown in full in the app and removable line by line: an agent that silently
-- accumulates opinions about you is not one you hand an unattended publish key.
create table brand_memory (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users on delete cascade,
  brand_id   uuid not null references brands on delete cascade,
  fact       text not null,
  source     text not null default 'agent' check (source in ('agent','user','metrics')),
  source_ref uuid,
  created_at timestamptz not null default now()
);
create index brand_memory_brand_idx on brand_memory (brand_id, created_at desc);

create table brand_settings (
  brand_id          uuid primary key references brands on delete cascade,
  user_id           uuid not null references auth.users on delete cascade,
  is_on             boolean  not null default false,
  posts_per_day     smallint not null default 1 check (posts_per_day between 1 and 6),
  platforms         platform[] not null default '{tiktok}',
  tone              text not null default '',
  -- ON: nothing publishes until a person has seen the actual media.
  -- OFF: the hands-off mode. Deliberately not the default -- see consent_records.
  requires_approval boolean not null default true,
  quiet_hours_start smallint not null default 22 check (quiet_hours_start between 0 and 23),
  quiet_hours_end   smallint not null default 7  check (quiet_hours_end   between 0 and 23),
  -- How long before a slot the media is made. Not at plan time: generating 30
  -- videos up front spends real money on posts that may be thrown away, and
  -- provider outputs expire in about a week so days 8-30 would rot unpublished.
  render_lead_hours smallint not null default 26 check (render_lead_hours between 2 and 72),
  fallback_policy   text not null default 'stock_then_skip'
                    check (fallback_policy in ('retry_only','stock_then_skip','skip')),
  updated_at        timestamptz not null default now()
);

-- Survives 0001 intact apart from the brand key. `weight` is honoured this time:
-- allocate_slots() does weighted-shortfall selection, where 0001's app-side
-- generate() went round-robin and quietly ignored it.
create table content_pillars (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users on delete cascade,
  brand_id   uuid not null references brands on delete cascade,
  name       text not null,
  detail     text not null default '',
  weight     smallint not null default 1 check (weight > 0),
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index content_pillars_brand_idx on content_pillars (brand_id) where is_enabled;

-- ------------------------------------------------------------ chat + agent

create table threads (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users on delete cascade,
  brand_id   uuid references brands on delete set null,
  title      text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index threads_user_idx on threads (user_id, updated_at desc);

create table agent_runs (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users on delete cascade,
  thread_id     uuid not null references threads on delete cascade,
  brand_id      uuid references brands on delete set null,
  status        agent_run_status not null default 'queued',
  model         text not null,
  claimed_by    text,
  claimed_at    timestamptz,
  lease_until   timestamptz,
  attempts      smallint not null default 0,
  input_tokens  integer not null default 0,
  output_tokens integer not null default 0,
  cost_cents    integer not null default 0,
  error         text,
  created_at    timestamptz not null default now(),
  finished_at   timestamptz
);
create index agent_runs_claimable_idx on agent_runs (created_at) where status = 'queued';
create index agent_runs_lease_idx on agent_runs (lease_until) where status = 'running';
-- One live run per thread. Two agents planning the same conversation at once
-- produce two plans and neither is what was asked for.
create unique index agent_runs_one_live_idx on agent_runs (thread_id)
  where status in ('queued','running');

create table messages (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  thread_id   uuid not null references threads on delete cascade,
  run_id      uuid references agent_runs on delete set null,
  seq         bigint not null,
  role        message_role not null,
  text        text not null default '',
  -- Points the client at a row to render instead of prose, e.g.
  -- {"kind":"plan_preview","plan_id":"..."} or {"kind":"consent_sheet","approval_id":"..."}.
  -- The plan is rendered live from `posts`, never from a transcript snapshot.
  render_hint jsonb,
  created_at  timestamptz not null default now(),
  unique (thread_id, seq)
);

-- The stream itself. Append-only; the client subscribes over Realtime and
-- reconnects with `seq > last_seen`, so replay needs no server-side session.
create table agent_events (
  run_id     uuid not null references agent_runs on delete cascade,
  seq        integer not null,
  user_id    uuid not null references auth.users on delete cascade,
  type       text not null check (type in ('text_delta','tool_start','tool_end','status','error','done')),
  payload    jsonb not null,
  created_at timestamptz not null default now(),
  primary key (run_id, seq)
);

create table tool_calls (
  id         uuid primary key default gen_random_uuid(),
  run_id     uuid not null references agent_runs on delete cascade,
  user_id    uuid not null references auth.users on delete cascade,
  name       text not null,
  args       jsonb not null,
  result     jsonb,
  status     text not null default 'running' check (status in ('running','ok','error','denied')),
  error      text,
  latency_ms integer,
  created_at timestamptz not null default now()
);
create index tool_calls_run_idx on tool_calls (run_id, created_at);

-- ------------------------------------------------------ platform accounts

create table platform_connections (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users on delete cascade,
  brand_id          uuid not null references brands on delete cascade,
  platform          platform not null,
  -- The swap point. 'tiktok_direct' is our own audited app; a broker such as
  -- Higgsfield would be another value, and the publisher picks an adapter on it.
  provider          text not null default 'tiktok_direct',
  provider_user_id  text not null,
  username          text not null,
  display_name      text not null default '',
  avatar_url        text,
  avatar_fetched_at timestamptz,
  scopes            text[] not null default '{}',
  status            connection_status not null default 'active',
  connected_at      timestamptz not null default now(),
  revoked_at        timestamptz,
  last_error        text,
  unique (brand_id, platform, provider_user_id)
);
create index platform_connections_brand_idx on platform_connections (brand_id) where status = 'active';

-- What the platform said about the creator, when we last asked. Consent binds
-- to a row here, so we can always say what the person was shown at the time.
create table creator_snapshots (
  id            uuid primary key default gen_random_uuid(),
  connection_id uuid not null references platform_connections on delete cascade,
  fetched_at    timestamptz not null default now(),
  username      text not null,
  nickname      text not null default '',
  avatar_url    text not null default '',
  privacy_level_options privacy_level[] not null,
  comment_disabled boolean not null default false,
  duet_disabled    boolean not null default false,
  stitch_disabled  boolean not null default false,
  max_video_post_duration_sec integer not null default 600
);
create index creator_snapshots_conn_idx on creator_snapshots (connection_id, fetched_at desc);

-- ------------------------------------------------------------ secrets

-- No grants, ever. Only the service role reaches this, and the ciphertext is
-- useless without the KEK, which lives in the worker's environment rather than
-- in the database. That is the whole point: a full dump is worth nothing.
create schema if not exists private;
revoke all on schema private from anon, authenticated;

create table private.platform_credentials (
  connection_id      uuid primary key references public.platform_connections on delete cascade,
  key_version        smallint not null,
  -- AES-256-GCM. AAD is connection_id || 'access' | 'refresh', so ciphertext
  -- moved into another row fails to decrypt -- otherwise anyone with SQL write
  -- access could swap tokens between users and post as somebody else.
  access_ct          bytea not null,
  access_expires_at  timestamptz not null,
  refresh_ct         bytea not null,
  refresh_expires_at timestamptz,
  -- TikTok rotates the refresh token on every use. Keeping one generation back
  -- makes a crash between "they issued a new one" and "we committed it"
  -- recoverable instead of permanently bricking the connection.
  prev_refresh_ct    bytea,
  refreshed_at       timestamptz,
  -- Single-flight guard. Two concurrent refreshes race and the loser's token is
  -- dead forever.
  refresh_lock       timestamptz,
  updated_at         timestamptz not null default now()
);

-- The user's own generation provider keys. Same scheme, same reasoning.
create table private.provider_credentials (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  provider     text not null,
  label        text not null default '',
  key_version  smallint not null,
  secret_ct    bytea not null,
  -- Every credential is probed before it is trusted, and re-probed when it
  -- starts failing. A key that silently stopped working must say so rather
  -- than producing nothing and blaming the model.
  last_probe_at     timestamptz,
  last_probe_ok     boolean,
  last_probe_detail text,
  created_at   timestamptz not null default now(),
  revoked_at   timestamptz,
  unique (user_id, provider, label)
);

-- ------------------------------------------------------------------ media

create table asset_licenses (
  id                   uuid primary key default gen_random_uuid(),
  provider             text not null,
  provider_asset_id    text,
  license_name         text not null,
  license_url          text,
  commercial_use       boolean not null,
  modification_allowed boolean not null,
  attribution_required boolean not null default false,
  attribution_text     text,
  captured_at          timestamptz not null default now(),
  -- The provider's payload, kept verbatim. If a licence is ever questioned, the
  -- answer is what they told us at the time, not what we summarised.
  raw                  jsonb not null default '{}'::jsonb
);

create table media_assets (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  brand_id    uuid references brands on delete cascade,
  kind        asset_kind not null,
  source      asset_source not null,
  rights      rights_status not null default 'pending',
  -- One place decides publishability, and it is a stored column so a trigger
  -- and an index can both use it.
  may_publish boolean generated always as (rights = 'cleared') stored,
  license_id  uuid references asset_licenses on delete set null,

  storage_bucket text,
  storage_path   text,
  mime           text,
  byte_size      bigint,
  checksum_sha256 text,
  width int, height int, duration_ms int, fps numeric(5,2),

  -- provenance
  provider                text,
  provider_asset_id       text,
  provider_url            text,
  -- Provider outputs expire in about seven days. Anything still pointing at a
  -- provider URL past this is about to become a 404 at publish time.
  provider_url_expires_at timestamptz,
  model    text,
  prompt   text,
  seed     bigint,
  parent_asset_id     uuid references media_assets on delete set null,
  style_reference_ids uuid[] not null default '{}',
  created_by_job      uuid,          -- FK added after generation_jobs exists

  created_at timestamptz not null default now(),
  deleted_at timestamptz,

  constraint stock_needs_license check (source <> 'stock' or license_id is not null),
  -- Cleared means we hold the bytes. A cleared asset that only exists on a
  -- provider's CDN is one expiry away from a failed post.
  constraint stored_or_pending  check (rights <> 'cleared' or storage_path is not null)
);
create index media_assets_brand_idx on media_assets (brand_id, created_at desc) where deleted_at is null;
create index media_assets_expiring_idx on media_assets (provider_url_expires_at)
  where storage_path is null and provider_url_expires_at is not null;

-- The publishable derivative, per destination. TikTok rejects PNG outright and
-- generators emit PNG, so the raw asset is almost never the thing that ships.
-- The publisher reads THIS table and never media_assets.storage_path, which is
-- what makes "a PNG reached TikTok" structurally impossible rather than a bug
-- waiting to happen.
create table asset_variants (
  id           uuid primary key default gen_random_uuid(),
  asset_id     uuid not null references media_assets on delete cascade,
  purpose      text not null,
  mime         text not null,
  storage_path text not null,
  byte_size    bigint not null,
  checksum_sha256 text not null,
  width int, height int, duration_ms int, fps numeric(5,2),
  created_at   timestamptz not null default now(),
  unique (asset_id, purpose)
);

-- Third-party images the person pasted for vibe. Deliberately its own table and
-- deliberately NOT an asset_source value: there is no join from here to
-- post_assets anywhere in the system, so a Pinterest image can steer what gets
-- generated and can never itself be published.
create table style_references (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  brand_id     uuid not null references brands on delete cascade,
  source_url   text,
  storage_path text not null,
  note         text not null default '',
  created_at   timestamptz not null default now()
);

create table music_tracks (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users on delete cascade,   -- null = shared library
  source        text not null check (source in ('tiktok_cml','licensed_library','generated','user_upload')),
  provider      text,
  provider_track_id text,
  title text, artist text, duration_ms int, bpm int,
  commercial_use_allowed boolean not null default false,
  territories   text[] not null default '{}',
  asset_id      uuid references media_assets on delete set null,
  created_at    timestamptz not null default now()
);

-- ------------------------------------------------------------------- jobs

create table generation_jobs (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  brand_id     uuid references brands on delete cascade,
  post_id      uuid,                                  -- FK added after posts exists
  kind         job_kind not null,
  provider     text not null default 'higgsfield',
  credential_id uuid,                                 -- private.provider_credentials
  status       job_status not null default 'queued',
  attempts     smallint not null default 0,
  max_attempts smallint not null default 3,
  input        jsonb not null,
  output       jsonb,
  asset_id     uuid references media_assets on delete set null,

  provider_request_id text,
  status_url          text,
  cancel_url          text,
  -- Provider webhooks are unsigned, so the callback path carries an unguessable
  -- per-job token. Even then the body is treated as a wake-up, never as truth:
  -- on receipt we re-GET status_url with our own key and believe that instead.
  webhook_token       text not null default encode(extensions.gen_random_bytes(24),'hex'),
  webhook_received_at timestamptz,

  run_at       timestamptz not null default now(),
  claimed_by   text,
  lease_until  timestamptz,
  submitted_at timestamptz,
  finished_at  timestamptz,
  poll_after   timestamptz,
  cost_cents   integer not null default 0,
  error        text,
  created_at   timestamptz not null default now()
);
create index generation_jobs_claim_idx on generation_jobs (run_at) where status = 'queued';
create index generation_jobs_poll_idx  on generation_jobs (poll_after) where status in ('submitted','running');
create index generation_jobs_lease_idx on generation_jobs (lease_until) where claimed_by is not null;
create unique index generation_jobs_token_idx on generation_jobs (webhook_token);

alter table media_assets
  add constraint media_assets_created_by_job_fkey
  foreign key (created_by_job) references generation_jobs on delete set null;

-- ------------------------------------------------------------ plan + posts

create table content_plans (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users on delete cascade,
  brand_id       uuid not null references brands on delete cascade,
  created_by_run uuid references agent_runs on delete set null,
  title          text not null default '',
  status         plan_status not null default 'draft',
  starts_on      date not null,
  days           smallint not null check (days between 1 and 60),
  posts_per_day  smallint not null check (posts_per_day between 1 and 6),
  brief          text not null default '',
  approved_at    timestamptz,
  approved_by    uuid references auth.users,
  created_at     timestamptz not null default now()
);
-- A brand runs one plan at a time. Two active plans double-book every slot.
create unique index content_plans_one_active_idx on content_plans (brand_id) where status = 'active';

create table posts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  brand_id    uuid not null references brands on delete cascade,
  plan_id     uuid references content_plans on delete cascade,
  pillar_id   uuid references content_pillars on delete set null,
  day_index   smallint,
  slot_index  smallint not null default 0,
  format      text not null default 'video' check (format in ('video','photo','carousel')),
  hook        text not null default '',
  script      text not null default '',
  concept     text not null default '',      -- what the media should show
  -- Kept from 0001 because it is the product: one line, in the model's own
  -- words, saying why this exists. A draft without one is refused.
  rationale   text not null,
  status      post_status not null default 'planned',
  render_tier text not null default 'deferred' check (render_tier in ('eager','deferred')),
  media_strategy text not null default 'generate'
                 check (media_strategy in ('generate','stock','user_upload','mixed')),
  scheduled_for timestamptz,
  render_after  timestamptz,                 -- scheduled_for - render_lead_hours
  failure_reason text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint failed_has_reason check (status <> 'failed' or failure_reason is not null),
  constraint rationale_not_blank check (length(btrim(rationale)) > 0)
);
create index posts_user_date_idx on posts (user_id, coalesce(scheduled_for, created_at) desc);
create index posts_plan_idx on posts (plan_id, day_index, slot_index);
create index posts_render_due_idx on posts (render_after)
  where status in ('scripted','sourcing') and render_after is not null;

alter table generation_jobs
  add constraint generation_jobs_post_fkey
  foreign key (post_id) references posts on delete cascade;

-- One post, N accounts. Everything that differs per destination lives here:
-- the caption, the consent, the rate limit, the platform's own post id.
create table post_targets (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users on delete cascade,
  post_id       uuid not null references posts on delete cascade,
  connection_id uuid not null references platform_connections on delete restrict,
  platform      platform not null,

  caption   text not null default '',
  hashtags  text[] not null default '{}',

  -- Captured at approval, replayed at publish, never inferred.
  privacy              privacy_level not null default 'SELF_ONLY',
  disable_comment      boolean not null default false,
  disable_duet         boolean not null default false,
  disable_stitch       boolean not null default false,
  -- Defaults TRUE: this product generates its media. Only lowered when every
  -- attached asset is stock or user-owned, and that is checked server-side.
  is_aigc              boolean not null default true,
  -- Whether a post is a paid partnership is a per-post legal fact, not a
  -- preference, so it is off by default and never inherited from a plan.
  brand_content_toggle boolean not null default false,
  brand_organic_toggle boolean not null default false,
  photo_cover_index    smallint,
  video_cover_ms       integer,
  music_track_id       uuid references music_tracks on delete set null,

  state          publish_state not null default 'pending',
  consent_id     uuid,                        -- FK added after consent_records
  content_digest bytea,
  provider_publish_id text,
  provider_post_id    text,
  published_at   timestamptz,
  failure_code   text,
  failure_reason text,
  metrics        jsonb not null default '{}'::jsonb,
  metrics_at     timestamptz,

  unique (post_id, connection_id),
  -- TikTok refuses branded content that is not public.
  constraint branded_must_be_public check (not brand_content_toggle or privacy <> 'SELF_ONLY'),
  constraint published_has_time check ((state = 'published') = (published_at is not null))
);
create index post_targets_state_idx on post_targets (state, post_id);
create index post_targets_conn_idx  on post_targets (connection_id, published_at desc);

create table post_assets (
  post_target_id uuid not null references post_targets on delete cascade,
  asset_id       uuid not null references media_assets on delete restrict,
  ordinal        smallint not null,
  role           text not null default 'primary'
                 check (role in ('primary','cover','carousel_item','audio')),
  primary key (post_target_id, ordinal)
);

-- --------------------------------------------------------------- approvals

create table approval_requests (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users on delete cascade,
  plan_id      uuid references content_plans on delete cascade,
  post_id      uuid references posts on delete cascade,
  requested_by_run uuid references agent_runs on delete set null,
  status       approval_status not null default 'pending',
  summary      jsonb not null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '7 days',
  resolved_at  timestamptz,
  check (plan_id is not null or post_id is not null)
);

-- Immutable. Append only, never updated, never deleted. This is the record of
-- what a person was actually shown and what they actually agreed to, and it is
-- worth nothing if it can be edited after the fact.
create table consent_records (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users on delete cascade,
  post_target_id uuid not null references post_targets on delete cascade,
  approval_id    uuid not null references approval_requests on delete restrict,
  connection_id  uuid not null references platform_connections on delete restrict,
  creator_snapshot_id uuid not null references creator_snapshots on delete restrict,

  -- sha256 over caption, ordered VARIANT checksums, privacy and flags. Hashing
  -- the bytes that ship rather than the asset ids means a re-render invalidates
  -- consent, which is correct: they agreed to a specific video, not to a slot.
  content_digest bytea not null,
  privacy        privacy_level not null,
  disable_comment boolean not null,
  disable_duet    boolean not null,
  disable_stitch  boolean not null,
  is_aigc         boolean not null,
  brand_content_toggle boolean not null,
  brand_organic_toggle boolean not null,

  -- What was on screen. The platform requires the creator be identified before
  -- publishing; this is how we can show that they were.
  consent_ui_version       text not null,
  shown_creator_username   text not null,
  shown_creator_avatar_url text not null,
  granted_at    timestamptz not null default now(),
  granted_ip    inet,
  granted_ua    text,
  revoked_at    timestamptz,
  revoke_reason text
);
create index consent_target_idx on consent_records (post_target_id) where revoked_at is null;

alter table post_targets
  add constraint post_targets_consent_fkey
  foreign key (consent_id) references consent_records on delete restrict;

-- ---------------------------------------------------------- publish queue

create table publish_jobs (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users on delete cascade,
  post_target_id uuid not null references post_targets on delete cascade,
  connection_id  uuid not null references platform_connections on delete cascade,
  run_at         timestamptz not null,
  state          publish_state not null default 'pending',
  attempts       smallint not null default 0,
  max_attempts   smallint not null default 4,
  claimed_by     text,
  lease_until    timestamptz,
  -- Anti-thundering-herd. If the worker is down for four hours, the backlog is
  -- NOT fired on recovery -- those rows fail as 'missed_window' and the person
  -- is told. Publishing forty posts in ten minutes is worse than publishing none.
  expires_at     timestamptz not null,
  last_error     text,
  created_at     timestamptz not null default now(),
  unique (post_target_id)
);
create index publish_jobs_due_idx on publish_jobs (run_at) where state = 'pending';
create index publish_jobs_lease_idx on publish_jobs (lease_until) where claimed_by is not null;

create table publish_attempts (
  id             uuid primary key default gen_random_uuid(),
  publish_job_id uuid not null references publish_jobs on delete cascade,
  connection_id  uuid not null references platform_connections on delete cascade,
  attempt_no     smallint not null,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  http_status    integer,
  provider_code  text,
  provider_publish_id text,
  outcome        text check (outcome in ('submitted','published','rejected','error','rate_limited')),
  detail         jsonb not null default '{}'::jsonb
);
create index publish_attempts_conn_idx on publish_attempts (connection_id, started_at desc);

-- Token bucket per account. Cheap to read and write, and no counting over a
-- ledger that grows forever. Bumped INSIDE the claim so two workers cannot both
-- decide they are under the limit.
create table account_rate_state (
  connection_id  uuid primary key references platform_connections on delete cascade,
  minute_window  timestamptz not null default date_trunc('minute', now()),
  minute_count   smallint not null default 0,
  day_window     date not null default current_date,
  day_count      smallint not null default 0,
  -- Under the platform's own ceiling on purpose. Riding the exact limit means
  -- every clock-skew rounding error is a rejection.
  max_per_minute smallint not null default 5,
  max_per_day    smallint not null default 12,
  cooldown_until timestamptz
);

-- ---------------------------------------------------------------- billing

create table plans_catalog (
  code               text primary key,
  monthly_image_gens int not null,
  monthly_video_gens int not null,
  monthly_llm_cents  int not null,
  max_brands         smallint not null,
  max_connections    smallint not null,
  max_plan_days      smallint not null
);

create table subscriptions (
  user_id   uuid primary key references auth.users on delete cascade,
  plan_code text not null references plans_catalog,
  provider  text not null default 'apple',
  original_transaction_id text,
  status    text not null default 'active' check (status in ('active','grace','expired','refunded')),
  current_period_start timestamptz not null default now(),
  current_period_end   timestamptz not null,
  updated_at timestamptz not null default now()
);

create table quota_counters (
  user_id      uuid not null references auth.users on delete cascade,
  period_start date not null,
  kind         text not null,
  used         integer not null default 0,
  limit_value  integer not null,
  primary key (user_id, period_start, kind)
);

create table usage_events (
  id         bigserial primary key,
  user_id    uuid not null references auth.users on delete cascade,
  brand_id   uuid,
  kind       text not null,
  units      integer not null,
  cost_cents integer not null default 0,
  ref_table  text,
  ref_id     uuid,
  created_at timestamptz not null default now()
);
create index usage_events_user_idx on usage_events (user_id, created_at desc);

-- ------------------------------------------------------------ operational

create table worker_heartbeats (
  worker_id text primary key,
  role      text not null check (role in ('orchestrator','jobs','media','publisher')),
  beat_at   timestamptz not null default now(),
  version   text
);

create table private.webhook_deliveries (
  id           uuid primary key default gen_random_uuid(),
  provider     text not null,
  external_id  text,
  headers      jsonb,
  body         jsonb,
  verified     boolean not null default false,
  processed_at timestamptz,
  received_at  timestamptz not null default now(),
  unique (provider, external_id)
);

create table private.audit_log (
  id            bigserial primary key,
  user_id       uuid,
  actor         text not null check (actor in ('user','agent','system')),
  action        text not null,
  subject_table text,
  subject_id    uuid,
  detail        jsonb not null default '{}'::jsonb,
  at            timestamptz not null default now()
);

-- ------------------------------------------------------------- invariants

-- user_id is denormalized onto almost everything so RLS is a single index scan
-- rather than a join to brands on every row. That is worth it, but it is only
-- safe if the two can never disagree.
create or replace function assert_brand_owner() returns trigger
language plpgsql as $$
declare owner uuid;
begin
  select user_id into owner from brands where id = new.brand_id;
  if owner is null then
    raise exception 'brand % does not exist', new.brand_id;
  end if;
  if owner <> new.user_id then
    raise exception 'brand % belongs to %, not %', new.brand_id, owner, new.user_id;
  end if;
  return new;
end $$;

create trigger posts_brand_owner        before insert or update of brand_id, user_id on posts
  for each row execute function assert_brand_owner();
create trigger plans_brand_owner        before insert or update of brand_id, user_id on content_plans
  for each row execute function assert_brand_owner();
create trigger pillars_brand_owner      before insert or update of brand_id, user_id on content_pillars
  for each row execute function assert_brand_owner();
create trigger connections_brand_owner  before insert or update of brand_id, user_id on platform_connections
  for each row execute function assert_brand_owner();

-- The rights gate. Nothing lands on a post unless we hold the bytes and the
-- provenance is good. The publisher re-checks this inside its claim as well:
-- the trigger stops the agent attaching something uncleared, the re-check
-- catches rights being revoked between approval and publish.
create or replace function assert_publishable_asset() returns trigger
language plpgsql as $$
begin
  if not exists (
    select 1 from media_assets m
     where m.id = new.asset_id
       and m.may_publish
       and m.storage_path is not null
       and m.deleted_at is null
  ) then
    raise exception 'asset % is not cleared for publication', new.asset_id;
  end if;
  return new;
end $$;

create trigger post_assets_rights_guard before insert or update on post_assets
  for each row execute function assert_publishable_asset();

create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create trigger posts_touch    before update on posts    for each row execute function touch_updated_at();
create trigger threads_touch  before update on threads  for each row execute function touch_updated_at();
create trigger pillars_touch  before update on content_pillars for each row execute function touch_updated_at();
create trigger settings_touch before update on brand_settings  for each row execute function touch_updated_at();

-- -------------------------------------------------------------------- RLS
--
-- 0001 used `for all using (auth.uid() = user_id)` on every table, which let any
-- client with a session set status='posted', stamp approved_at, or rewrite a
-- rationale. Reads are broad; writes are narrow and mostly server-side.
--
-- auth.uid() is wrapped as (select auth.uid()) throughout so Postgres evaluates
-- it once per query as an InitPlan instead of once per row. On a 30-day plan
-- across three accounts that is one call rather than ninety.

alter table profiles             enable row level security;
alter table brands               enable row level security;
alter table brand_memory         enable row level security;
alter table brand_settings       enable row level security;
alter table content_pillars      enable row level security;
alter table threads              enable row level security;
alter table messages             enable row level security;
alter table agent_runs           enable row level security;
alter table agent_events         enable row level security;
alter table tool_calls           enable row level security;
alter table platform_connections enable row level security;
alter table creator_snapshots    enable row level security;
alter table asset_licenses       enable row level security;
alter table media_assets         enable row level security;
alter table asset_variants       enable row level security;
alter table style_references     enable row level security;
alter table music_tracks         enable row level security;
alter table generation_jobs      enable row level security;
alter table content_plans        enable row level security;
alter table posts                enable row level security;
alter table post_targets         enable row level security;
alter table post_assets          enable row level security;
alter table approval_requests    enable row level security;
alter table consent_records      enable row level security;
alter table publish_jobs         enable row level security;
alter table publish_attempts     enable row level security;
alter table account_rate_state   enable row level security;
alter table subscriptions        enable row level security;
alter table quota_counters       enable row level security;
alter table usage_events         enable row level security;
alter table plans_catalog        enable row level security;
alter table worker_heartbeats    enable row level security;

-- Nothing client-side by default; grants are handed back one table at a time.
revoke all on all tables in schema public from anon, authenticated;

-- --- fully owned by the person: read and write

grant select, insert, update, delete on brands, content_pillars, brand_memory,
  style_references, threads to authenticated;
grant select, update on brand_settings to authenticated;
grant select, insert on messages to authenticated;
grant select, update on profiles to authenticated;

create policy own_profiles       on profiles       for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_brands         on brands         for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_brand_memory   on brand_memory   for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_brand_settings on brand_settings for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_pillars        on content_pillars for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_style_refs     on style_references for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy own_threads        on threads        for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- A person may say things. The assistant's turn is written by the worker.
create policy own_messages_read  on messages for select to authenticated
  using ((select auth.uid()) = user_id);
create policy own_messages_write on messages for insert to authenticated
  with check ((select auth.uid()) = user_id and role = 'user');

-- --- read-only to the client, written by the service role

grant select on agent_runs, agent_events, tool_calls, platform_connections,
  creator_snapshots, asset_licenses, asset_variants, music_tracks,
  generation_jobs, content_plans, posts, post_targets, post_assets,
  approval_requests, consent_records, publish_jobs, quota_counters,
  usage_events, subscriptions, plans_catalog to authenticated;

create policy own_agent_runs   on agent_runs   for select to authenticated using ((select auth.uid()) = user_id);
create policy own_agent_events on agent_events for select to authenticated using ((select auth.uid()) = user_id);
create policy own_tool_calls   on tool_calls   for select to authenticated using ((select auth.uid()) = user_id);
create policy own_connections  on platform_connections for select to authenticated using ((select auth.uid()) = user_id);
create policy own_plans        on content_plans for select to authenticated using ((select auth.uid()) = user_id);
create policy own_targets      on post_targets  for select to authenticated using ((select auth.uid()) = user_id);
create policy own_jobs         on generation_jobs for select to authenticated using ((select auth.uid()) = user_id);
create policy own_approvals    on approval_requests for select to authenticated using ((select auth.uid()) = user_id);
-- Read only, always. Consent is written by an Edge Function that validates it
-- against a live creator snapshot; a consent record the client wrote is just
-- whatever the client felt like claiming.
create policy own_consent      on consent_records for select to authenticated using ((select auth.uid()) = user_id);
create policy own_publish_jobs on publish_jobs for select to authenticated using ((select auth.uid()) = user_id);
create policy own_quota        on quota_counters for select to authenticated using ((select auth.uid()) = user_id);
create policy own_usage        on usage_events  for select to authenticated using ((select auth.uid()) = user_id);
create policy own_subscription on subscriptions for select to authenticated using ((select auth.uid()) = user_id);
create policy catalog_readable on plans_catalog for select to authenticated using (true);

create policy own_snapshots on creator_snapshots for select to authenticated
  using (exists (select 1 from platform_connections c
                  where c.id = connection_id and c.user_id = (select auth.uid())));
create policy own_variants on asset_variants for select to authenticated
  using (exists (select 1 from media_assets m
                  where m.id = asset_id and m.user_id = (select auth.uid())));
create policy own_post_assets on post_assets for select to authenticated
  using (exists (select 1 from post_targets t
                  where t.id = post_target_id and t.user_id = (select auth.uid())));
create policy licenses_readable on asset_licenses for select to authenticated using (true);
create policy music_readable on music_tracks for select to authenticated
  using (user_id is null or user_id = (select auth.uid()));

-- Posts: readable, and hand-editable only in the fields a person writes, and
-- only while the post has not already gone out.
grant update (hook, script, concept) on posts to authenticated;
create policy own_posts_read on posts for select to authenticated
  using ((select auth.uid()) = user_id);
create policy own_posts_edit on posts for update to authenticated
  using ((select auth.uid()) = user_id and status not in ('posted','failed'))
  with check ((select auth.uid()) = user_id);

-- Media: a person may upload their own. They may NOT declare their own rights
-- cleared -- that is decided server-side, from the licence or the provenance.
grant select, insert on media_assets to authenticated;
create policy own_media_read on media_assets for select to authenticated
  using ((select auth.uid()) = user_id);
create policy own_media_upload on media_assets for insert to authenticated
  with check ((select auth.uid()) = user_id
              and source = 'user_upload'
              and rights = 'pending');

-- --- no client access at all
-- publish_attempts, account_rate_state and worker_heartbeats are operational.
-- Their RLS is enabled with no policy, which denies everything by default; the
-- service role bypasses RLS and is the only reader.

-- ------------------------------------------------------------------ storage

insert into storage.buckets (id, name, public)
values ('media', 'media', false)
on conflict (id) do nothing;

-- Paths are {user_id}/{asset_id}/{variant}.{ext}, so a leaked signed URL leaks
-- exactly one object for fifteen minutes and the policy is a prefix match.
create policy own_media_objects on storage.objects for select to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy own_media_upload_objects on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ------------------------------------------------------------------- seed

insert into plans_catalog (code, monthly_image_gens, monthly_video_gens,
                           monthly_llm_cents, max_brands, max_connections, max_plan_days)
values
  -- No video generation on free. A free tier that generates video is a free
  -- video generator with extra steps, and it will be used as one.
  ('free',    30,    0,   200, 1, 1,  7),
  ('creator', 300,  60,  2000, 3, 5, 30),
  ('studio', 1000, 250,  8000, 10, 20, 60)
on conflict (code) do nothing;
