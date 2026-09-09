-- Asking "who can do this", and recording what a connection turned out to be.
--
-- The single most important function here is `capabilities_for`. It is what the
-- agent calls instead of importing a vendor, and everything else exists to keep
-- its answer true.

-- What can this person actually do right now, for one capability?
--
-- Returns models, best first, across every provider they have connected. The
-- agent asks for `video_generation` and gets rows; it never learns that
-- Higgsfield exists.
--
-- Only `active` connections and `available` models. A model that stopped being
-- offered is left in the table with `available = false` rather than deleted,
-- because a job that used it still points at it and "why did it pick that" has
-- to remain answerable.
create or replace function capabilities_for(p_capability text, p_user uuid default null)
returns table (
  model_id      uuid,
  connection_id uuid,
  provider_slug text,
  provider_name text,
  external_id   text,
  label         text,
  metadata      jsonb,
  rank          smallint
)
language sql
security definer
set search_path = public
as $$
  select m.id, c.id, p.slug, p.name, m.external_id, m.label, m.metadata, m.rank
    from connection_models m
    join connections c on c.id = m.connection_id
    join providers   p on p.id = c.provider_id
   where m.capability = p_capability
     and m.available
     and c.status = 'active'
     and c.revoked_at is null
     -- Callable by the person (auth.uid()) and by the worker (service role,
     -- which passes the user explicitly because it has no session).
     and c.user_id = coalesce(p_user, (select auth.uid()))
   order by m.rank, p.slug, m.label;
$$;

-- Everything this person has connected, for the Plus menu and You.
create or replace function my_connections()
returns table (
  id            uuid,
  provider_slug text,
  provider_name text,
  status        text,
  account_label text,
  capabilities  text[],
  model_count   integer,
  last_error_code text,
  connected_at  timestamptz
)
language sql
security definer
set search_path = public
as $$
  select c.id, p.slug, p.name, c.status, c.account_label,
         coalesce(array_agg(distinct cc.capability)
                  filter (where cc.capability is not null), '{}'),
         (select count(*)::int from connection_models m
           where m.connection_id = c.id and m.available),
         c.last_error_code,
         c.connected_at
    from connections c
    join providers p on p.id = c.provider_id
    left join connection_capabilities cc on cc.connection_id = c.id
   where c.user_id = (select auth.uid())
     and c.revoked_at is null
   group by c.id, p.slug, p.name
   order by c.connected_at desc nulls last;
$$;

-- What can be connected that has not been. Drives the connect list.
create or replace function connectable_providers()
returns table (slug text, name text, auth_kind text, docs_url text)
language sql
security definer
set search_path = public
as $$
  select p.slug, p.name, p.auth_kind, p.docs_url
    from providers p
   where p.enabled
     and not exists (
       select 1 from connections c
        where c.provider_id = p.id
          and c.user_id = (select auth.uid())
          and c.revoked_at is null
     )
   order by p.name;
$$;

-- Starts a connection and returns the row to attach an authorization to.
--
-- Deliberately service-role only. A client that could insert into `connections`
-- could mark one `active` without ever authorising anything, and every
-- capability lookup downstream trusts that status.
create or replace function begin_connection(p_user uuid, p_provider_slug text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_provider uuid; v_id uuid;
begin
  select id into v_provider from providers where slug = p_provider_slug and enabled;
  if v_provider is null then
    raise exception 'unknown provider %', p_provider_slug using errcode = 'P0002';
  end if;

  -- Reconnecting replaces rather than duplicates: the partial unique index
  -- allows exactly one live row per person per provider, and a stale one would
  -- otherwise block the new authorization with a constraint error the person
  -- can do nothing about.
  update connections
     set revoked_at = now(), status = 'revoked'
   where user_id = p_user and provider_id = v_provider and revoked_at is null;

  insert into connections (user_id, provider_id, status)
  values (p_user, v_provider, 'pending')
  returning id into v_id;

  return v_id;
end $$;

-- Marks a connection live once a token is in hand.
create or replace function activate_connection(
  p_connection uuid,
  p_label      text default '',
  p_external   text default null
) returns void
language sql
security definer
set search_path = public
as $$
  update connections
     set status = 'active',
         account_label = coalesce(nullif(p_label, ''), account_label),
         external_account_id = coalesce(p_external, external_account_id),
         connected_at = coalesce(connected_at, now()),
         last_error_code = null,
         last_checked_at = now()
   where id = p_connection;
$$;

-- Records what discovery found, as one replacement rather than a diff.
--
-- Models arrive as a jsonb array of
--   {capability, external_id, label, metadata, rank}
--
-- Everything previously known for this connection is marked unavailable first
-- and then re-marked by what came back, so a model the provider has withdrawn
-- disappears from `capabilities_for` without being deleted out from under the
-- jobs that used it.
create or replace function record_discovery(p_connection uuid, p_models jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer := 0;
begin
  if jsonb_typeof(p_models) <> 'array' then
    raise exception 'models must be an array' using errcode = '22023';
  end if;

  update connection_models set available = false where connection_id = p_connection;

  insert into connection_models (connection_id, capability, external_id, label, metadata, rank, available, last_seen_at)
  select p_connection,
         m->>'capability',
         m->>'external_id',
         coalesce(nullif(m->>'label', ''), m->>'external_id'),
         coalesce(m->'metadata', '{}'::jsonb),
         coalesce((m->>'rank')::smallint, 100),
         true,
         now()
    from jsonb_array_elements(p_models) m
   where m->>'capability' is not null
     and m->>'external_id' is not null
     -- A capability nobody declared is dropped rather than inserted: the agent
     -- switches on this vocabulary, so an adapter inventing one at runtime
     -- would produce rows nothing can route to.
     and exists (select 1 from capabilities c where c.slug = m->>'capability')
  on conflict (connection_id, external_id) do update
    set capability   = excluded.capability,
        label        = excluded.label,
        metadata     = excluded.metadata,
        rank         = excluded.rank,
        available    = true,
        last_seen_at = now();

  get diagnostics v_count = row_count;

  -- The capability list follows from the models, so it can never disagree with
  -- them -- a connection claiming video_generation with no video model is a
  -- promise the agent would act on and then fail to keep.
  delete from connection_capabilities where connection_id = p_connection;
  insert into connection_capabilities (connection_id, capability)
  select distinct connection_id, capability
    from connection_models
   where connection_id = p_connection and available
  on conflict do nothing;

  return v_count;
end $$;

-- Something went wrong with this connection, in the shared vocabulary.
create or replace function fault_connection(p_connection uuid, p_code text, p_status text default 'error')
returns void
language sql
security definer
set search_path = public
as $$
  update connections
     set status = case when p_status in ('active','expired','revoked','error')
                       then p_status else 'error' end,
         last_error_code = p_code,
         last_checked_at = now()
   where id = p_connection;
$$;

-- The person disconnects. Secrets go with it, by cascade.
create or replace function forget_connection(p_connection uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_owner uuid;
begin
  select user_id into v_owner from connections where id = p_connection;
  if v_owner is null then
    raise exception 'no such connection' using errcode = 'P0002';
  end if;
  if (select auth.uid()) is distinct from v_owner then
    raise exception 'not yours' using errcode = '42501';
  end if;

  -- Deleted rather than flagged: this is the one place someone is explicitly
  -- asking for their credential to stop existing, and honouring that literally
  -- is worth more than the audit trail of a token nobody can use.
  delete from private.connection_secrets where connection_id = p_connection;

  update connections
     set status = 'revoked', revoked_at = now()
   where id = p_connection;
end $$;

revoke execute on function capabilities_for(text, uuid)          from anon, public;
revoke execute on function my_connections()                      from anon, public;
revoke execute on function connectable_providers()               from anon, public;
revoke execute on function begin_connection(uuid, text)          from anon, authenticated, public;
revoke execute on function activate_connection(uuid, text, text) from anon, authenticated, public;
revoke execute on function record_discovery(uuid, jsonb)         from anon, authenticated, public;
revoke execute on function fault_connection(uuid, text, text)    from anon, authenticated, public;
revoke execute on function forget_connection(uuid)               from anon, public;

grant execute on function capabilities_for(text, uuid) to authenticated;
grant execute on function my_connections()             to authenticated;
grant execute on function connectable_providers()      to authenticated;
grant execute on function forget_connection(uuid)      to authenticated;
