-- Making the key somebody already pasted look like a connection.
--
-- 0025 gave connections, capabilities and models. 0012 gave bring-your-own-key
-- credentials. Right now they are two systems that do not know about each
-- other, and routing by capability would find nothing for the one person who
-- has actually connected a generator -- which would be a rewrite that breaks
-- the only working install to make an abstraction tidy.
--
-- So the old rows become connections. Two decisions make that possible without
-- re-encrypting anything:
--
-- The connection id is set EQUAL to the credential id. The ciphertext in 0012
-- is sealed with AAD `${credentialId}:provider`, so keeping the id makes
-- `${connectionId}:provider` decrypt the same bytes. Minting a new id would
-- mean re-sealing every secret, which needs the key, which lives in the Edge
-- Function runtime and deliberately not here.
--
-- And `auth_kind` moves onto the connection. It was on `providers`, which was
-- wrong the moment the registry started keying adapters on `slug:auth_kind`:
-- one vendor is reachable two ways, and Higgsfield is now both -- MCP for
-- anyone connecting today, a pasted key for anyone who already did.

alter table connections add column if not exists auth_kind text
  check (auth_kind in ('mcp_oauth','oauth2','api_key'));

comment on column connections.auth_kind is
  'How THIS connection authenticates. Null means the provider default -- one vendor can be reachable more than one way.';

-- Existing pasted keys, as connections.
--
-- Idempotent: re-running skips anything already bridged, so this is safe to
-- apply against a database where somebody connected in between.
insert into connections (id, user_id, provider_id, auth_kind, status, account_label, connected_at, created_at)
select c.id,
       c.user_id,
       p.id,
       'api_key',
       case when c.last_probe_ok is false then 'error' else 'active' end,
       coalesce(nullif(c.label, ''), 'API key'),
       c.created_at,
       c.created_at
  from private.provider_credentials c
  join providers p on p.slug = c.provider
 where c.revoked_at is null
   and octet_length(c.secret_ct) > 0
   and not exists (select 1 from connections x where x.id = c.id)
on conflict (id) do nothing;

-- The five vertical models the REST adapter supports, for every bridged
-- connection. An API key cannot be asked what it may use -- Higgsfield has no
-- entitlement endpoint -- so this records what the adapter can attempt, and the
-- chain walking past whatever the account lacks is what keeps it honest.
insert into connection_models (connection_id, capability, external_id, label, metadata, rank, available)
select c.id, 'video_generation', m.path, m.label,
       jsonb_build_object('aspect_ratios', jsonb_build_array('9:16'), 'via', 'rest'),
       m.rank, true
  from connections c
  cross join (values
    ('/bytedance/seedance/v1/lite/text-to-video',     'Seedance Lite',    0),
    ('/bytedance/seedance/v1/pro/fast/text-to-video', 'Seedance Pro',    10),
    ('/kling-video/v2.1/master/text-to-video',        'Kling 2.1 Master',20),
    ('/sora-2/text-to-video',                         'Sora 2',          30),
    ('/sora-2/text-to-video/pro',                     'Sora 2 Pro',      40)
  ) as m(path, label, rank)
 where c.auth_kind = 'api_key'
   and c.revoked_at is null
on conflict (connection_id, external_id) do nothing;

insert into connection_capabilities (connection_id, capability)
select distinct connection_id, capability from connection_models
on conflict do nothing;

-- Reports the connection's own auth_kind, and finds the secret in either place.
--
-- The coalesce on the ciphertext is what lets one code path serve both doors:
-- an OAuth connection keeps its token in private.connection_secrets, a bridged
-- one keeps it where 0012 put it, and the caller only has to know which AAD to
-- use -- which it derives from auth_kind.
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
  select c.id, c.user_id, p.slug,
         coalesce(c.auth_kind, p.auth_kind),
         p.mcp_url, p.api_base, c.status,
         encode(coalesce(s.access_ct, pc.secret_ct), 'hex'),
         encode(s.refresh_ct, 'hex'),
         s.access_expires_at
    from connections c
    join providers p on p.id = c.provider_id
    left join private.connection_secrets   s  on s.connection_id = c.id
    left join private.provider_credentials pc on pc.id = c.id and pc.revoked_at is null
   where c.id = p_connection
     and c.revoked_at is null;
$$;

revoke execute on function read_connection(uuid) from anon, authenticated, public;

-- Same widening for the worker's single-answer lookup.
create or replace function connection_for_capability(p_user uuid, p_capability text)
returns table (connection_id uuid, provider_slug text, auth_kind text, endpoint text, model text)
language sql
security definer
set search_path = public
as $$
  select c.id, p.slug, coalesce(c.auth_kind, p.auth_kind),
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

revoke execute on function connection_for_capability(uuid, text) from anon, authenticated, public;

-- `forget_connection` must now also revoke a bridged credential, or
-- disconnecting would leave the key working and the connection gone.
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

  delete from private.connection_secrets where connection_id = p_connection;

  -- Revoked rather than deleted: 0012 keeps the row and clears it, and
  -- `generator_for_user` already filters on this, so the old screen and the new
  -- one agree about what is gone.
  update private.provider_credentials
     set revoked_at = now()
   where id = p_connection and revoked_at is null;

  update connections
     set status = 'revoked', revoked_at = now()
   where id = p_connection;
end $$;

revoke execute on function forget_connection(uuid) from anon, public;
grant  execute on function forget_connection(uuid) to authenticated;
