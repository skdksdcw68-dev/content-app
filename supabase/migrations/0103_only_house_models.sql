-- Nobody connects their own models, keys or MCP servers any more (Abel,
-- 8 Nov 2026: "nothing works from now on. It only works on my own models").
--
-- Everything that picks a model for a job goes through capabilities_for, so
-- it now sees only the house connection. A connection somebody made before
-- stays in the table, untouched and unused; putting the 0068 definitions back
-- brings it back.

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
     and c.is_house
   order by m.rank, p.slug, m.label;
$$;

-- Every job now runs on our own models, so whether it is on our money is
-- simply whether a house model can do it.
create or replace function uses_house_generator(p_user uuid, p_capability text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
      from connection_models m
      join connections c on c.id = m.connection_id
     where m.capability = p_capability
       and m.available
       and c.status = 'active'
       and c.revoked_at is null
       and c.is_house
  );
$$;
