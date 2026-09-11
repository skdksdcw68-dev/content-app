-- Signing in must be reachable for somebody who once pasted a key.
--
-- `connectable_providers` hid a provider as soon as the person had ANY live
-- connection to it. Abel pasted a Higgsfield key on 7 Sep, 0028 bridged it into
-- `connections`, and from then on "Sign in to Higgsfield" appeared nowhere in
-- the app -- the one way in he actually wanted was hidden behind the one he
-- did not. And the key could only be removed with a swipe nobody finds.
--
-- Now: a provider is hidden only when the person is connected through the
-- provider's OWN door (signed in, for Higgsfield). A pasted key leaves sign-in
-- on offer, flagged so the app can say it replaces the key.
--
-- Also: `my_connections` says which door each connection came through, so a
-- row can read "API key" or "Signed in", and it stops listing sign-in attempts
-- that were abandoned -- a `pending` row older than the ten-minute authorisation
-- window will never finish, and "Finishing…" forever is a lie.
--
-- Both change their returned columns, so both are dropped first (42P13).

drop function if exists my_connections();
create function my_connections()
returns table (
  id            uuid,
  provider_slug text,
  provider_name text,
  auth_kind     text,
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
  select c.id, p.slug, p.name,
         coalesce(c.auth_kind, p.auth_kind),
         c.status, c.account_label,
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
     and not (c.status = 'pending' and c.created_at < now() - interval '15 minutes')
   group by c.id, p.slug, p.name, p.auth_kind
   order by c.connected_at desc nulls last;
$$;

drop function if exists connectable_providers();
create function connectable_providers()
returns table (slug text, name text, auth_kind text, docs_url text, replaces_key boolean)
language sql
security definer
set search_path = public
as $$
  select p.slug, p.name, p.auth_kind, p.docs_url,
         exists (
           select 1 from connections k
            where k.provider_id = p.id
              and k.user_id = (select auth.uid())
              and k.revoked_at is null
              and coalesce(k.auth_kind, p.auth_kind) = 'api_key'
         )
    from providers p
   where p.enabled
     and not exists (
       select 1 from connections c
        where c.provider_id = p.id
          and c.user_id = (select auth.uid())
          and c.revoked_at is null
          and c.status = 'active'
          and coalesce(c.auth_kind, p.auth_kind) = p.auth_kind
     )
   order by p.name;
$$;

revoke execute on function my_connections()        from anon, public;
revoke execute on function connectable_providers() from anon, public;
grant  execute on function my_connections()        to authenticated;
grant  execute on function connectable_providers() to authenticated;
