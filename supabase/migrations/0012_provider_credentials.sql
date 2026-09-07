-- Bring your own generator.
--
-- The cost argument decided this, not a preference. A pooled key at a thousand
-- people times thirty videos a month is roughly nine thousand dollars of
-- generation. The user's own key moves that to the user, and the same design
-- makes the app provider-agnostic for free: nothing here knows what Higgsfield
-- is, only that a credential exists, was probed, and belongs to somebody.
--
-- Same shape as platform credentials in 0005/0006: write and read through
-- security definer functions, service role only, and the `private` schema stays
-- unreachable over PostgREST. The ciphertext is sealed by the Edge Function
-- runtime; Postgres never holds the key.

-- Reserves a row and returns its id.
--
-- The AAD the ciphertext is bound to includes the credential id, which does not
-- exist until the row does. So the row is written first with a placeholder and
-- the caller seals against the returned id -- see set_provider_secret below.
-- Doing it the other way round would mean either a nullable ciphertext column
-- or an id chosen by the client, and both are worse.
--
-- Takes the user explicitly rather than reading auth.uid(). Only the Edge
-- Function calls this, and it calls it with the service role, where auth.uid()
-- is null -- the JWT was already verified there, one line before.
create or replace function begin_provider_credential(
  p_user     uuid,
  p_provider text,
  p_label    text default ''
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  insert into private.provider_credentials (user_id, provider, label, key_version, secret_ct)
  values (p_user, p_provider, coalesce(p_label, ''), 1, '\x'::bytea)
  on conflict (user_id, provider, label) do update
    set revoked_at = null
  returning id into v_id;

  return v_id;
end $$;

-- Fills in the sealed secret and the result of probing it.
--
-- `p_ok` is not optional and there is no path that stores a credential without
-- one: a key that was never tried is a key that fails at 3am inside a job,
-- where the error reads as the model being broken.
create or replace function set_provider_secret(
  p_credential_id uuid,
  p_secret_ct     text,
  p_ok            boolean,
  p_detail        text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update private.provider_credentials
     set secret_ct         = decode(p_secret_ct, 'hex'),
         key_version       = 1,
         last_probe_at     = now(),
         last_probe_ok     = p_ok,
         last_probe_detail = p_detail
   where id = p_credential_id;
end $$;

create or replace function read_provider_credential(p_credential_id uuid)
returns table (
  user_id     uuid,
  provider    text,
  label       text,
  key_version smallint,
  secret_ct   text,
  revoked_at  timestamptz
)
language sql
security definer
set search_path = public
as $$
  select c.user_id, c.provider, c.label, c.key_version,
         encode(c.secret_ct, 'hex'), c.revoked_at
    from private.provider_credentials c
   where c.id = p_credential_id;
$$;

-- What the app is allowed to know: that a generator is connected, when it was
-- last checked, and whether it worked. Never the secret, and never enough to
-- reconstruct it.
create or replace function my_generators()
returns table (
  id            uuid,
  provider      text,
  label         text,
  last_probe_at timestamptz,
  last_probe_ok boolean,
  last_probe_detail text,
  created_at    timestamptz
)
language sql
security definer
set search_path = public
as $$
  select c.id, c.provider, c.label, c.last_probe_at, c.last_probe_ok,
         c.last_probe_detail, c.created_at
    from private.provider_credentials c
   where c.user_id = auth.uid()
     and c.revoked_at is null
   order by c.created_at;
$$;

create or replace function forget_generator(p_credential_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Ownership written out, because security definer bypasses RLS and this
  -- takes an id straight from a client.
  update private.provider_credentials
     set revoked_at = now(),
         -- Overwritten as well as revoked. A revoked row that still holds a
         -- working key is a key nobody thinks they have any more.
         secret_ct = '\x'::bytea
   where id = p_credential_id
     and user_id = auth.uid();
end $$;

-- begin/set are the Edge Function's half of the write and must not be callable
-- from a phone: set_provider_secret in particular takes the probe result as an
-- argument, and a client that could pass `true` could store a key that has
-- never been tried.
revoke execute on function begin_provider_credential(uuid, text, text) from anon, authenticated, public;
revoke execute on function set_provider_secret(uuid, text, boolean, text) from anon, authenticated, public;
revoke execute on function read_provider_credential(uuid) from anon, authenticated, public;

revoke execute on function my_generators() from anon, public;
revoke execute on function forget_generator(uuid) from anon, public;
grant execute on function my_generators() to authenticated;
grant execute on function forget_generator(uuid) to authenticated;

-- The one a worker asks for: whichever generator this person has, ready to use.
--
-- Returns the ciphertext, not the key. Decryption happens in the Edge Function
-- runtime that holds the key, so a database dump is worth nothing on its own --
-- the same argument as platform tokens in 0005.
create or replace function generator_for_user(p_user uuid)
returns table (
  id            uuid,
  provider      text,
  secret_ct     text,
  last_probe_ok boolean
)
language sql
security definer
set search_path = public
as $$
  select c.id, c.provider, encode(c.secret_ct, 'hex'), c.last_probe_ok
    from private.provider_credentials c
   where c.user_id = p_user
     and c.revoked_at is null
     and octet_length(c.secret_ct) > 0
   order by c.last_probe_ok desc nulls last, c.created_at
   limit 1;
$$;

revoke execute on function generator_for_user(uuid) from anon, authenticated, public;
