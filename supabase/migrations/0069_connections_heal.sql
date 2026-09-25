-- A connection that just handed us a working token is working.
--
-- 🔴 THIS IS WHY EVERY CONNECTION IN THIS PROJECT HAS DIED.
--
-- 25 Sep 2026. The house generator was switched on at 11:19 and proved live at
-- 11:22: a brand-new account saw 41 models and Higgsfield answered, refreshing
-- the token from 05:25 today to 11:22 tomorrow. Ninety minutes later the same
-- account showed "Nothing connected yet", and the connection read:
--
--     status = 'expired',  revoked_at = null,  token valid until tomorrow
--
-- A VALID TOKEN ON AN EXPIRED CONNECTION. `capabilities_for` requires
-- `status = 'active'`, so 41 models vanished while the credential behind them
-- was fine.
--
-- Two faults, and they compound:
--
-- 1. `tokens.ts` calls `markExpired` on a single 400 or 401 from the refresh
--    endpoint. Clerk ROTATES refresh tokens and invalidates the old one the
--    moment it is used. `poll-generations` runs EVERY MINUTE, so two opens
--    near an expiry race: the first rotates the token, the second presents the
--    one it read a moment earlier, gets a 400 because that one is now spent,
--    and concludes the grant is gone. It is not. It is one second old.
--
-- 2. Nothing ever set the status back. `store_connection_secret` writes the
--    new token and says nothing about the connection, so a moment of bad luck
--    at 11:30 is permanent until somebody signs in again by hand. That is
--    exactly what "your generator needs reconnecting" has been telling Abel
--    for weeks, and why a connection with 40 discovered models sat revoked
--    beside a broken one (see 0062).
--
-- This half is the healing: storing a fresh token marks the connection active
-- again and clears the error. The other half -- not giving up on the first
-- 400 -- is in `_shared/connectors/tokens.ts`.
create or replace function store_connection_secret(
  p_connection uuid,
  p_access_ct  text,
  p_refresh_ct text default null,
  p_expires    timestamptz default null,
  p_scope      text default ''
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
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
        refresh_ct        = coalesce(excluded.refresh_ct, private.connection_secrets.refresh_ct),
        scope             = excluded.scope,
        updated_at        = now();

  -- The healing. A connection somebody deliberately disconnected stays gone --
  -- `revoked_at` is the person's decision and is never undone here. Anything
  -- else that has just produced a working token is active again.
  update connections
     set status = 'active',
         last_error_code = null,
         last_checked_at = now()
   where id = p_connection
     and revoked_at is null
     and status <> 'active';
end;
$$;

-- And put the one this broke back, since its token is valid until tomorrow.
update connections
   set status = 'active', last_error_code = null
 where status = 'expired'
   and revoked_at is null
   and exists (
     select 1 from private.connection_secrets s
      where s.connection_id = connections.id
        and s.access_expires_at > now()
   );
