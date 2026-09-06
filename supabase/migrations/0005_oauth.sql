-- OAuth plumbing: somewhere to park a pending authorization, and a way for an
-- Edge Function to write a credential it can never read back.

-- ------------------------------------------------------------------ state

-- One row per authorization in flight. It exists to answer, when a browser
-- comes back from TikTok, "did we start this, and who for" -- without trusting
-- anything the redirect carries beyond an opaque handle.
--
-- In `public` rather than `private` because PostgREST cannot see `private` at
-- all, and this is written and read by an Edge Function on every connect. It is
-- protected by having no policies and no grants: RLS on with zero policies
-- denies every client outright, and only the service role, which bypasses RLS,
-- can touch it.
create table oauth_states (
  state         text primary key,
  user_id       uuid not null references auth.users on delete cascade,
  brand_id      uuid not null references brands on delete cascade,
  platform      platform not null,
  -- PKCE. Not required for a confidential web client, which is what we are, but
  -- stored so the same table serves a native flow later without a migration.
  code_verifier text,
  -- Where to send the browser once the exchange succeeds, so the app can be
  -- reopened on the screen the person left.
  return_to     text not null default 'autocast://oauth/done',
  created_at    timestamptz not null default now(),
  -- Short. An authorization that has sat unfinished for ten minutes is an
  -- abandoned tab, not a person waiting.
  expires_at    timestamptz not null default now() + interval '10 minutes'
);
create index oauth_states_expiry_idx on oauth_states (expires_at);

alter table oauth_states enable row level security;
revoke all on oauth_states from anon, authenticated;

-- Housekeeping. Abandoned authorizations are the common case, not the rare one.
create or replace function purge_oauth_states() returns int
language plpgsql set search_path = public as $$
declare v_n int;
begin
  delete from oauth_states where expires_at < now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke execute on function purge_oauth_states() from anon, authenticated;

-- ------------------------------------------------------------ credentials

-- The only way into private.platform_credentials.
--
-- PostgREST is configured to expose `public` alone, so an Edge Function cannot
-- reach the private schema directly however privileged its key is. This is the
-- deliberate hole in that wall, and it is one-directional: it writes ciphertext
-- and returns nothing. Nothing in the API surface can read a token back out --
-- only the worker, over a direct database connection, can do that.
--
-- Ciphertext arrives as hex text because bytea does not survive JSON cleanly.
create or replace function store_platform_credential(
  p_connection_id      uuid,
  p_key_version        smallint,
  p_access_ct          text,
  p_access_expires_at  timestamptz,
  p_refresh_ct         text,
  p_refresh_expires_at timestamptz
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_access_ct !~ '^[0-9a-f]+$' or p_refresh_ct !~ '^[0-9a-f]+$' then
    raise exception 'ciphertext must be lowercase hex';
  end if;

  insert into private.platform_credentials as c (
    connection_id, key_version,
    access_ct, access_expires_at,
    refresh_ct, refresh_expires_at,
    refreshed_at, updated_at
  )
  values (
    p_connection_id, p_key_version,
    decode(p_access_ct, 'hex'), p_access_expires_at,
    decode(p_refresh_ct, 'hex'), p_refresh_expires_at,
    now(), now()
  )
  on conflict (connection_id) do update
    set key_version        = excluded.key_version,
        access_ct          = excluded.access_ct,
        access_expires_at  = excluded.access_expires_at,
        -- Keep one generation back. TikTok rotates the refresh token on every
        -- use, so a crash between "they issued a new one" and "we committed it"
        -- would otherwise brick the connection permanently.
        prev_refresh_ct    = c.refresh_ct,
        refresh_ct         = excluded.refresh_ct,
        refresh_expires_at = excluded.refresh_expires_at,
        refresh_lock       = null,
        refreshed_at       = now(),
        updated_at         = now();
end $$;

revoke execute on function store_platform_credential(uuid, smallint, text, timestamptz, text, timestamptz)
  from anon, authenticated, public;
