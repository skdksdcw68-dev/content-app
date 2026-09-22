-- 0055: a screen of video generators to choose from, and your own MCP server.
--
-- Abel, 22 Sep 2026: "connect to video generator should redirect you to some
-- video generator things" -- a list, with Higgsfield shown as the best one
-- (a partnership is being applied for) -- "and they can also manually [add an]
-- MCP [server] so it directly redirects them to the MCP".
--
-- Two things change in the data:
--
-- 1. A provider can be FEATURED, with a tagline. The app leads with whichever
--    row says so; it never spells a vendor's name itself (design rule since
--    12 Sep: "do not hardcode higgsfield").
--
-- 2. A provider can be OWNED. Anyone signed in can add an MCP server by
--    address; it becomes a `providers` row that only they can see, and from
--    there it is connected exactly like the catalogue ones: discovery of the
--    authorization server from the endpoint, dynamic client registration,
--    PKCE sign-in, tool discovery. Nothing about the flow knew Higgsfield's
--    name, which is why this is a column and not a new table.

alter table providers add column if not exists owner_id uuid references auth.users on delete cascade;
alter table providers add column if not exists featured boolean not null default false;
alter table providers add column if not exists tagline  text;

create index if not exists providers_owner on providers (owner_id) where owner_id is not null;

update providers
   set featured = true,
       tagline  = 'Kling, Seedance, Veo, Nano Banana and eighty more models behind one sign-in. The account you already have works.'
 where slug = 'higgsfield';

-- Shared rows for everyone; owned rows for their owner only.
drop policy if exists providers_read on providers;
create policy providers_read on providers for select to authenticated
  using (enabled and (owner_id is null or owner_id = (select auth.uid())));

-- What is on offer, featured first, then the catalogue, then your own.
-- Returned columns change, so the function is dropped first (42P13).
drop function if exists connectable_providers();
create function connectable_providers()
returns table (
  slug         text,
  name         text,
  auth_kind    text,
  docs_url     text,
  replaces_key boolean,
  featured     boolean,
  tagline      text,
  mine         boolean
)
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
         ),
         p.featured,
         p.tagline,
         p.owner_id is not null
    from providers p
   where p.enabled
     and (p.owner_id is null or p.owner_id = (select auth.uid()))
     and not exists (
       select 1 from connections c
        where c.provider_id = p.id
          and c.user_id = (select auth.uid())
          and c.revoked_at is null
          and c.status = 'active'
          and coalesce(c.auth_kind, p.auth_kind) = p.auth_kind
     )
   order by p.featured desc, (p.owner_id is not null), p.name;
$$;

revoke execute on function connectable_providers() from anon, public;
grant  execute on function connectable_providers() to authenticated;

-- Your own MCP server, by address. Returns the slug to connect.
--
-- The same address added twice is the same row, renamed -- somebody who
-- mistyped the name should not end up with two servers. The address must be
-- https: the sign-in that follows sends a code to it.
create or replace function add_mcp_server(p_name text, p_url text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := (select auth.uid());
  v_name text := btrim(coalesce(p_name, ''));
  v_url  text := btrim(coalesce(p_url, ''));
  v_slug text;
begin
  if v_user is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if v_url !~* '^https://[^[:space:]]+$' then
    raise exception 'The MCP address must start with https://' using errcode = '22023';
  end if;
  if v_name = '' then
    -- The host, when no name was given: "mcp.example.ai".
    v_name := regexp_replace(v_url, '^https://([^/]+).*$', '\1', 'i');
  end if;
  v_name := left(v_name, 60);

  select p.slug into v_slug
    from providers p
   where p.owner_id = v_user and p.mcp_url = v_url and p.enabled;

  if v_slug is not null then
    update providers set name = v_name where slug = v_slug;
    return v_slug;
  end if;

  v_slug := 'mcp-' || replace(gen_random_uuid()::text, '-', '');
  insert into providers (slug, name, auth_kind, mcp_url, owner_id)
  values (v_slug, v_name, 'mcp_oauth', v_url, v_user);
  return v_slug;
end $$;

revoke execute on function add_mcp_server(text, text) from anon, public;
grant  execute on function add_mcp_server(text, text) to authenticated;

-- Taking your own server off the list. Its connections are revoked with it;
-- the row stays (disabled) so past jobs still say what made them.
create or replace function remove_mcp_server(p_slug text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_provider uuid;
begin
  select id into v_provider
    from providers
   where slug = p_slug and owner_id = (select auth.uid());
  if v_provider is null then
    raise exception 'Not one of your servers.' using errcode = 'P0002';
  end if;
  update connections
     set revoked_at = now(), status = 'revoked'
   where provider_id = v_provider and revoked_at is null;
  update providers set enabled = false where id = v_provider;
end $$;

revoke execute on function remove_mcp_server(text) from anon, public;
grant  execute on function remove_mcp_server(text) to authenticated;
