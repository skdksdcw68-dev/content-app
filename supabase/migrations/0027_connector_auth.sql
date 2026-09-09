-- The state an OAuth round trip needs, and the way tokens are read back.
--
-- Everything here is service-role only. There is no path by which a client
-- reads a token, writes a token, or completes somebody else's authorization --
-- which is the difference between "the app has your Higgsfield account" and
-- "the app can be talked into having anyone's".

-- One authorization in flight.
--
-- `state` is the primary key and it is the CSRF defence: the provider hands it
-- back on the redirect, and a callback carrying a state nobody stashed is
-- discarded. `verifier` is the PKCE secret -- the client is public, so this is
-- the only thing stopping a stolen code being redeemed by whoever stole it, and
-- it must never leave the server.
create table if not exists private.connection_authorizations (
  state         text primary key,
  connection_id uuid not null references public.connections on delete cascade,
  provider_id   uuid not null references public.providers on delete cascade,
  verifier      text not null,
  -- Where to send the person afterwards, so the app closes its browser sheet on
  -- something it recognises.
  return_scheme text not null default '',
  -- Ten minutes is generous for a login and short enough that an abandoned
  -- attempt cannot be resumed by somebody who finds the URL later.
  expires_at    timestamptz not null default now() + interval '10 minutes',
  created_at    timestamptz not null default now()
);

create index if not exists connection_authorizations_expiry
  on private.connection_authorizations (expires_at);

-- Stashes one attempt.
create or replace function stash_authorization(
  p_state text, p_connection uuid, p_provider uuid, p_verifier text, p_scheme text default ''
) returns void
language sql
security definer
set search_path = public
as $$
  -- Anything stale goes at the same time, so the table cannot grow on abandoned
  -- logins and there is nothing to schedule.
  delete from private.connection_authorizations where expires_at < now();

  insert into private.connection_authorizations (state, connection_id, provider_id, verifier, return_scheme)
  values (p_state, p_connection, p_provider, p_verifier, coalesce(p_scheme, ''));
$$;

-- Takes one attempt, once.
--
-- Deleting as it reads is deliberate: a code may be redeemed exactly once, and
-- a replayed callback should find nothing rather than a second chance.
create or replace function claim_authorization(p_state text)
returns table (connection_id uuid, provider_id uuid, verifier text, return_scheme text)
language sql
security definer
set search_path = public
as $$
  delete from private.connection_authorizations a
   where a.state = p_state
     and a.expires_at > now()
  returning a.connection_id, a.provider_id, a.verifier, a.return_scheme;
$$;

-- Our registration with a provider, kept so DCR runs once rather than per user.
create or replace function upsert_provider_client(
  p_slug text, p_client_id text, p_secret_ct text, p_redirect text, p_registered jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_provider uuid;
begin
  select id into v_provider from providers where slug = p_slug;
  if v_provider is null then
    raise exception 'unknown provider %', p_slug using errcode = 'P0002';
  end if;

  insert into provider_clients (provider_id, client_id, client_secret_ct, redirect_uri, registered)
  values (v_provider, p_client_id,
          case when p_secret_ct is null then null else decode(p_secret_ct, 'hex') end,
          p_redirect, coalesce(p_registered, '{}'::jsonb))
  on conflict (provider_id) do update
    set client_id        = excluded.client_id,
        client_secret_ct = excluded.client_secret_ct,
        redirect_uri     = excluded.redirect_uri,
        registered       = excluded.registered,
        registered_at    = now();
end $$;

create or replace function read_provider_client(p_slug text)
returns table (client_id text, client_secret_ct text, redirect_uri text)
language sql
security definer
set search_path = public
as $$
  select c.client_id, encode(c.client_secret_ct, 'hex'), c.redirect_uri
    from provider_clients c
    join providers p on p.id = c.provider_id
   where p.slug = p_slug;
$$;

-- Writes the sealed tokens for a connection.
create or replace function store_connection_secret(
  p_connection uuid,
  p_access_ct  text,
  p_refresh_ct text default null,
  p_expires    timestamptz default null,
  p_scope      text default ''
) returns void
language sql
security definer
set search_path = public
as $$
  insert into private.connection_secrets
    (connection_id, access_ct, access_expires_at, refresh_ct, scope, updated_at)
  values (
    p_connection,
    decode(p_access_ct, 'hex'),
    p_expires,
    case when p_refresh_ct is null then null else decode(p_refresh_ct, 'hex') end,
    coalesce(p_scope, ''),
    now()
  )
  on conflict (connection_id) do update
    set access_ct         = excluded.access_ct,
        access_expires_at = excluded.access_expires_at,
        -- A refresh that came back null does not erase the one we hold: some
        -- providers issue it once, on the first authorization, and never again.
        refresh_ct        = coalesce(excluded.refresh_ct, private.connection_secrets.refresh_ct),
        scope             = excluded.scope,
        updated_at        = now();
$$;

-- Reads the ciphertext back, with the provider details needed to use it.
--
-- Returns ciphertext and never plaintext: decryption happens in the Edge
-- Function runtime that holds the key, so a database dump is worth nothing on
-- its own. Same argument as platform tokens in 0005.
create or replace function read_connection(p_connection uuid)
returns table (
  connection_id uuid,
  user_id       uuid,
  provider_slug text,
  auth_kind     text,
  mcp_url       text,
  api_base      text,
  status        text,
  access_ct     text,
  refresh_ct    text,
  access_expires_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select c.id, c.user_id, p.slug, p.auth_kind, p.mcp_url, p.api_base, c.status,
         encode(s.access_ct, 'hex'),
         encode(s.refresh_ct, 'hex'),
         s.access_expires_at
    from connections c
    join providers p on p.id = c.provider_id
    left join private.connection_secrets s on s.connection_id = c.id
   where c.id = p_connection
     and c.revoked_at is null;
$$;

-- The connection to use for one capability, for one person.
--
-- What the worker calls: it has no session, so the user is explicit, and it
-- wants one answer rather than a list. Ordered the same way `capabilities_for`
-- orders, so the worker and the agent agree on what "best" means.
create or replace function connection_for_capability(p_user uuid, p_capability text)
returns table (connection_id uuid, provider_slug text, auth_kind text, endpoint text, model text)
language sql
security definer
set search_path = public
as $$
  select c.id, p.slug, p.auth_kind,
         coalesce(p.mcp_url, p.api_base),
         m.external_id
    from connection_models m
    join connections c on c.id = m.connection_id
    join providers   p on p.id = c.provider_id
   where c.user_id = p_user
     and c.status = 'active'
     and c.revoked_at is null
     and m.capability = p_capability
     and m.available
   order by m.rank, p.slug
   limit 1;
$$;

revoke execute on function stash_authorization(text, uuid, uuid, text, text) from anon, authenticated, public;
revoke execute on function claim_authorization(text)                          from anon, authenticated, public;
revoke execute on function upsert_provider_client(text, text, text, text, jsonb) from anon, authenticated, public;
revoke execute on function read_provider_client(text)                         from anon, authenticated, public;
revoke execute on function store_connection_secret(uuid, text, text, timestamptz, text) from anon, authenticated, public;
revoke execute on function read_connection(uuid)                              from anon, authenticated, public;
revoke execute on function connection_for_capability(uuid, text)              from anon, authenticated, public;
