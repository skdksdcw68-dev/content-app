-- Keep what a connection actually offered, not just what we understood.
--
-- The first real Higgsfield connection came back with zero capabilities, and
-- there was no way to find out why: discovery kept only the tools it could map,
-- so a server offering fifteen tools we did not recognise looked identical to a
-- server offering nothing. Diagnosing it meant catching a live session at the
-- right moment.
--
-- So the raw list is stored alongside the mapped one. It answers the question
-- operations will ask first -- "what does this connection expose?" -- and it is
-- the difference between a mapping bug and a provider that genuinely offers
-- nothing. It also makes new capabilities visible: a tool the provider added
-- yesterday shows up here before anybody has written a mapping for it.
--
-- Names and descriptions only. Never input schemas that might echo account
-- data back, and never anything from the credential.

alter table connections add column if not exists discovered_tools jsonb;
alter table connections add column if not exists discovered_at timestamptz;

comment on column connections.discovered_tools is
  'Every tool the provider reported at last discovery, mapped or not: [{name, description, capability}]. A capability of null is a tool nothing routes to yet.';

create or replace function record_tools(p_connection uuid, p_tools jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  update connections
     set discovered_tools = p_tools,
         discovered_at = now()
   where id = p_connection;
$$;

revoke execute on function record_tools(uuid, jsonb) from anon, authenticated, public;
