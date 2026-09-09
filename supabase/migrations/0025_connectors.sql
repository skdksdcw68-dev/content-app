-- The connector layer: who can do what, for whom.
--
-- Generation currently reaches Higgsfield by importing it. `_shared/generate.ts`
-- has `import { submit } from "./higgsfield.ts"` at the top, and every comment
-- in that file claims the design is provider-agnostic. It is not: adding image
-- generation today would hardcode a second vendor in the same place, and adding
-- a second video provider would mean the agent knowing both.
--
-- What this replaces that with:
--
--   agent -> "who can do video_generation for this user?"
--         -> connection_models rows
--         -> adapter for that connection's provider
--         -> the provider
--
-- The agent never names a vendor. It names a capability.
--
-- Normalised on purpose, and specifically NOT one wide provider table with
-- Higgsfield's fields in it. A provider is a row, a user's connection to it is a
-- row, and what that connection can actually do is discovered and stored as
-- rows -- because two users of the same provider genuinely do have different
-- models available, which is exactly the wall generation hit in September.
--
-- Nothing here touches `private.provider_credentials` from 0012. Bring-your-own
-- key still works, unchanged, and becomes one auth_kind among several rather
-- than the only way in.

-- --------------------------------------------------------------- vocabulary

-- The closed set of things a provider can do. Closed because the agent
-- switches on these, and a capability nobody planned for is a capability
-- nothing can route to -- better to add a row here in a migration than to let
-- an adapter invent one at runtime.
create table if not exists capabilities (
  slug        text primary key,
  label       text not null,
  -- What kind of work it is, so cost and autonomy policy can reason about
  -- classes rather than enumerating every slug.
  kind        text not null check (kind in ('generate','read','write','research')),
  -- Roughly what it costs to run once. Not a price -- a tier, because real
  -- prices are per-model and live on connection_models.
  weight      text not null default 'medium' check (weight in ('free','light','medium','heavy')),
  created_at  timestamptz not null default now()
);

insert into capabilities (slug, label, kind, weight) values
  ('video_generation', 'Video generation', 'generate', 'heavy'),
  ('image_generation', 'Image generation', 'generate', 'medium'),
  ('audio_generation', 'Audio generation', 'generate', 'medium'),
  ('voice_generation', 'Voice generation', 'generate', 'medium'),
  ('text_generation',  'Text generation',  'generate', 'light'),
  ('transcription',    'Transcription',    'read',     'light'),
  ('file_read',        'Read files',       'read',     'free'),
  ('file_write',       'Write files',      'write',    'free'),
  ('research',         'Research',         'research', 'medium'),
  ('web_access',       'Web access',       'read',     'light')
on conflict (slug) do nothing;

-- ---------------------------------------------------------------- providers

-- Who exists at all. Higgsfield is one row.
create table if not exists providers (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique,
  name        text not null,
  -- How a person connects. `mcp_oauth` is the one this migration exists for:
  -- the provider runs an MCP server behind OAuth, we register ourselves with
  -- Dynamic Client Registration and the user simply logs in. `api_key` is the
  -- 0012 path, kept because some providers offer nothing else.
  auth_kind   text not null check (auth_kind in ('mcp_oauth','oauth2','api_key')),
  -- For mcp_oauth: the MCP endpoint. Discovery of everything else -- the
  -- authorization server, the registration endpoint, the scopes -- comes from
  -- the well-known documents at connect time rather than being pinned here,
  -- because a provider is allowed to move its own endpoints.
  mcp_url     text,
  api_base    text,
  docs_url    text,
  -- Off means it does not appear in the connect list. Not deleted: a provider
  -- withdrawn today still has connections and jobs pointing at it.
  enabled     boolean not null default true,
  created_at  timestamptz not null default now()
);

insert into providers (slug, name, auth_kind, mcp_url, api_base, docs_url) values
  ('higgsfield', 'Higgsfield', 'mcp_oauth',
   'https://mcp.higgsfield.ai/mcp', 'https://api.higgsfield.ai', 'https://docs.higgsfield.ai')
on conflict (slug) do nothing;

-- Our own registration with a provider, from Dynamic Client Registration.
--
-- One row per provider, not per user: DCR issues a client id for the
-- application, and every user's authorization then runs against it. Registering
-- once and reusing it is both correct and the difference between one record on
-- their side and one per install.
create table if not exists provider_clients (
  provider_id   uuid primary key references providers on delete cascade,
  client_id     text not null,
  -- Null for a public client, which is what Higgsfield issues -- PKCE carries
  -- the security instead. Sealed when a provider does issue one.
  client_secret_ct bytea,
  redirect_uri  text not null,
  -- Kept so a provider moving its endpoints is a re-registration rather than a
  -- mystery, and so we can see what it agreed to.
  registered    jsonb not null default '{}'::jsonb,
  registered_at timestamptz not null default now()
);

-- -------------------------------------------------------------- connections

-- One person's connection to one provider. No secrets here.
create table if not exists connections (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users on delete cascade,
  provider_id   uuid not null references providers on delete restrict,

  status        text not null default 'pending'
                check (status in ('pending','active','expired','revoked','error')),

  -- What to show the person so they recognise which account this is. An email
  -- or a display name from the token claims -- never a credential, and never
  -- anything that would let the client reconstruct one.
  account_label text not null default '',
  external_account_id text,

  -- The last thing that went wrong, as a code from the shared failure
  -- vocabulary. The provider's own words stay on the job.
  last_error_code text,
  last_checked_at timestamptz,
  connected_at  timestamptz,
  revoked_at    timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- One live connection per provider per person. A second one is a reconnection,
-- and the old row is revoked rather than left to race it.
create unique index if not exists connections_one_live
  on connections (user_id, provider_id)
  where revoked_at is null;

create index if not exists connections_user_idx on connections (user_id, status);

create trigger connections_touch before update on connections
  for each row execute function touch_updated_at();

-- The tokens. Same shape and the same reasoning as private.platform_credentials
-- in 0002: a schema with no grants at all, AES-256-GCM, and AAD bound to the
-- connection id so ciphertext moved into another row fails to decrypt. Without
-- that binding, anyone with SQL write access could swap one person's token into
-- another person's connection and spend their credits.
create table if not exists private.connection_secrets (
  connection_id     uuid primary key references public.connections on delete cascade,
  key_version       smallint not null default 1,
  access_ct         bytea not null,
  access_expires_at timestamptz,
  refresh_ct        bytea,
  -- Single-flight guard, for the same reason TikTok needs one: two concurrent
  -- refreshes race and the loser's token is dead forever.
  refresh_lock      timestamptz,
  refreshed_at      timestamptz,
  scope             text not null default '',
  updated_at        timestamptz not null default now()
);

-- ------------------------------------------------------------- capabilities

-- What this connection turned out to be able to do. Discovered, never assumed:
-- two accounts on the same provider have different models, which is precisely
-- the wall generation hit when Seedance was not provisioned.
create table if not exists connection_capabilities (
  connection_id uuid not null references connections on delete cascade,
  capability    text not null references capabilities on delete restrict,
  discovered_at timestamptz not null default now(),
  primary key (connection_id, capability)
);

-- The models behind those capabilities.
create table if not exists connection_models (
  id            uuid primary key default gen_random_uuid(),
  connection_id uuid not null references connections on delete cascade,
  capability    text not null references capabilities on delete restrict,

  -- What the provider calls it -- an endpoint path, a tool name, a model id.
  -- Opaque here on purpose: only that provider's adapter interprets it.
  external_id   text not null,
  label         text not null,

  -- Everything a chooser needs and nothing it has to guess: durations,
  -- resolutions, aspect ratios, cost, whatever that provider reports. jsonb
  -- because the shape is the provider's, and normalising it into columns would
  -- mean a migration every time one adds a knob.
  metadata      jsonb not null default '{}'::jsonb,

  -- Ordering hint for "best available", lower is preferred. Set by the adapter
  -- from cost and quality, overridable later by the person.
  rank          smallint not null default 100,
  available     boolean not null default true,
  last_seen_at  timestamptz not null default now(),

  unique (connection_id, external_id)
);

create index if not exists connection_models_lookup
  on connection_models (connection_id, capability, available, rank);

-- ---------------------------------------------------------------------- RLS

alter table providers               enable row level security;
alter table capabilities            enable row level security;
alter table connections             enable row level security;
alter table connection_capabilities enable row level security;
alter table connection_models       enable row level security;

-- The catalogue is public knowledge; there is nothing in it worth hiding and
-- the connect screen has to list it.
create policy providers_read    on providers    for select to authenticated using (enabled);
create policy capabilities_read on capabilities for select to authenticated using (true);

-- Everything about a connection is readable by its owner and writable by
-- nobody. Connecting, discovering and revoking all go through functions, so
-- there is no path by which a client marks its own connection active or
-- invents a capability it does not have.
create policy connections_read on connections for select to authenticated
  using ((select auth.uid()) = user_id);

create policy connection_caps_read on connection_capabilities for select to authenticated
  using (exists (
    select 1 from connections c
     where c.id = connection_id and c.user_id = (select auth.uid())
  ));

create policy connection_models_read on connection_models for select to authenticated
  using (exists (
    select 1 from connections c
     where c.id = connection_id and c.user_id = (select auth.uid())
  ));

grant select on providers, capabilities, connections,
               connection_capabilities, connection_models to authenticated;

comment on table connections is
  'A person''s link to a provider. Secrets live in private.connection_secrets; this table is safe to read.';
comment on table connection_models is
  'Discovered per connection, never assumed -- two accounts on one provider expose different models.';
