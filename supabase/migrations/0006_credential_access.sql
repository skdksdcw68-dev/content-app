-- Reading a credential back, and rotating it.
--
-- 0005 gave the Edge Functions a way to write an encrypted token and no way to
-- read one. That was right for OAuth, where the function only ever stores what
-- it just received. It stops being enough at the approval screen: TikTok
-- requires the account's CURRENT privacy options be shown before a post, and
-- fetching those means calling TikTok as the creator, which means holding their
-- access token for the length of one request.
--
-- So: a read path, with the same shape as the write one. Service role only, no
-- grants to anon or authenticated, and PostgREST still cannot see the private
-- schema at all. What changes is that a server-side function can now decrypt --
-- and it still returns ciphertext, so the key never leaves the runtime that
-- holds it.

create or replace function read_platform_credential(p_connection_id uuid)
returns table (
  key_version        smallint,
  access_ct          text,
  access_expires_at  timestamptz,
  refresh_ct         text,
  refresh_expires_at timestamptz,
  refresh_lock       timestamptz
)
language sql
security definer
set search_path = public
as $$
  select c.key_version,
         encode(c.access_ct, 'hex'),
         c.access_expires_at,
         encode(c.refresh_ct, 'hex'),
         c.refresh_expires_at,
         c.refresh_lock
    from private.platform_credentials c
   where c.connection_id = p_connection_id;
$$;

revoke execute on function read_platform_credential(uuid) from anon, authenticated, public;

-- Claims the right to refresh, or reports that somebody else already has it.
--
-- TikTok issues a NEW refresh token every time one is used and invalidates the
-- old one. Two concurrent refreshes therefore race, and the loser is left
-- holding a token that will never work again -- a connection bricked with no
-- error anywhere. This is the lock that prevents it: the first caller wins, the
-- rest are told to wait and re-read.
create or replace function claim_credential_refresh(
  p_connection_id uuid,
  p_lease interval default '30 seconds'
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_got boolean;
begin
  update private.platform_credentials
     set refresh_lock = now() + p_lease
   where connection_id = p_connection_id
     and coalesce(refresh_lock, '-infinity') < now()
  returning true into v_got;

  return coalesce(v_got, false);
end $$;

revoke execute on function claim_credential_refresh(uuid, interval) from anon, authenticated, public;

-- Records the state of a connection when something goes wrong with it, so the
-- app can say "reconnect" instead of failing silently on every future post.
create or replace function mark_connection_unhealthy(
  p_connection_id uuid,
  p_status connection_status,
  p_error text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update platform_connections
     set status = p_status,
         last_error = p_error,
         revoked_at = case when p_status = 'revoked' then now() else revoked_at end
   where id = p_connection_id;
end $$;

revoke execute on function mark_connection_unhealthy(uuid, connection_status, text)
  from anon, authenticated, public;
