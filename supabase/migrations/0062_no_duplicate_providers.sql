-- Adding a server we already know about hands back the one we know about.
--
-- 🔴 This is why not one video was ever made. Pasting
-- "https://mcp.higgsfield.ai/mcp" into "add your own MCP server" minted a
-- private provider with a slug like `mcp-82f9e48b...`. The adapter's tool and
-- model tables are keyed by provider, so that connection matched nothing: it
-- discovered ONE placeholder model per capability instead of Higgsfield's
-- forty, and every generation against it died with `no_models`. Seventeen of
-- Abel's posts failed that way (24 Sep 2026) while a working built-in
-- Higgsfield connection sat revoked beside it.
--
-- mcp.ts now reads its tables by the server's HOST, so existing duplicates
-- start working. This stops new ones being made at all: the same address is
-- the same provider, and the built-in row -- with its registered OAuth client
-- and its catalogue -- is the one to use.
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
  v_host text;
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

  v_host := lower(regexp_replace(v_url, '^https://([^/]+).*$', '\1', 'i'));

  -- A shared provider on the same host wins. Compared by host rather than by
  -- the whole address, because /mcp and /mcp/ and a trailing query are the
  -- same server and a person typing an address should not have to know that.
  select p.slug into v_slug
    from providers p
   where p.owner_id is null
     and p.enabled
     and p.mcp_url is not null
     and lower(regexp_replace(p.mcp_url, '^https://([^/]+).*$', '\1', 'i')) = v_host
   limit 1;
  if v_slug is not null then
    return v_slug;
  end if;

  -- Then one of their own, by host as well, so pasting the same server twice
  -- with a different path does not make a second row.
  select p.slug into v_slug
    from providers p
   where p.owner_id = v_user
     and p.enabled
     and p.mcp_url is not null
     and lower(regexp_replace(p.mcp_url, '^https://([^/]+).*$', '\1', 'i')) = v_host
   limit 1;

  if v_slug is not null then
    update providers set name = v_name, mcp_url = v_url where slug = v_slug;
    return v_slug;
  end if;

  v_slug := 'mcp-' || replace(gen_random_uuid()::text, '-', '');
  insert into providers (slug, name, auth_kind, mcp_url, owner_id)
  values (v_slug, v_name, 'mcp_oauth', v_url, v_user);
  return v_slug;
end $$;

revoke execute on function add_mcp_server(text, text) from anon, public;
grant  execute on function add_mcp_server(text, text) to authenticated;

-- The duplicates already made. Disabled, not deleted: their connections and
-- past jobs still name them, and a job's history must not change because a
-- row was tidied. `mcp.higgfield.ai` is a typo of Higgsfield's host that
-- could never have resolved.
update public.providers p
   set enabled = false
 where p.owner_id is not null
   and p.enabled
   and p.mcp_url is not null
   and lower(regexp_replace(p.mcp_url, '^https://([^/]+).*$', '\1', 'i')) in (
     'mcp.higgsfield.ai', 'higgsfield.ai', 'mcp.higgfield.ai'
   );
