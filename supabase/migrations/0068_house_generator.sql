-- Autocast's own generator, so nobody has to connect one.
--
-- Abel, 25 Sep 2026: "i guess its better to choose something like our own
-- model instead of a connector."
--
-- He is right, and the evidence is this account. Not one video has ever been
-- made. Every single cause was the connector: a private MCP provider that
-- discovered one placeholder model instead of forty (0062), an OAuth chain
-- asking the wrong authorization server, a connection revoked on the Google
-- account while a working one with forty-one models sat on the Apple account
-- and was never asked. The product does not work until somebody completes a
-- multi-step sign-in with a third party, and most people never will.
--
-- So: a connection may be marked `is_house`, and then EVERY signed-in person
-- can generate through it. Their own connection still wins when they have one
-- -- somebody who connected their own Higgsfield is paying for it and must not
-- be metered against our plan caps.
--
-- 🔴 THE THING THAT MAKES THIS SAFE IS THE QUOTA, NOT THIS COLUMN. A house
-- connection is our money. `plans_catalog` already carries `monthly_video_gens`
-- (free 0, creator 60, studio 250) and `consume_quota` already spends it; what
-- was missing is anything calling it for generation. `_shared/generate.ts`
-- does now, BEFORE the job row and only when the job will run on the house
-- connection. Do not mark a connection `is_house` on a deployment where that
-- check has been removed.
alter table public.connections
  add column if not exists is_house boolean not null default false;

comment on column public.connections.is_house is
  'Autocast''s own generator: usable by every signed-in person, metered against plans_catalog.monthly_video_gens. Their own connection is preferred when they have one.';

-- At most one house connection per provider, so "the house generator" is a
-- thing rather than a guess between two.
create unique index if not exists connections_one_house_per_provider
  on public.connections (provider_id)
  where is_house and revoked_at is null;

-- Everything that can do a job, for this person.
--
-- Unchanged except that the house connection is included, and sorted last
-- among equals: `own` is 0 for their own rows and 1 for the house, so a
-- person with their own Higgsfield gets their own Higgsfield and the house
-- account is never touched.
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
     -- Theirs, or the house one. Callable by the person (auth.uid()) and by
     -- the worker (service role, which passes the user explicitly because it
     -- has no session).
     and (
       c.user_id = coalesce(p_user, (select auth.uid()))
       or c.is_house
     )
   order by
     -- Their own first, always.
     (case when c.user_id = coalesce(p_user, (select auth.uid())) then 0 else 1 end),
     m.rank, p.slug, m.label;
$$;

-- Whether this job will run on our money, asked BEFORE anything is spent.
-- True when the person has no working connection of their own for this
-- capability, and there is a house one that can do it.
create or replace function uses_house_generator(p_user uuid, p_capability text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select
    not exists (
      select 1
        from connection_models m
        join connections c on c.id = m.connection_id
       where m.capability = p_capability
         and m.available
         and c.status = 'active'
         and c.revoked_at is null
         and c.user_id = p_user
         and not c.is_house
    )
    and exists (
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

revoke execute on function uses_house_generator(uuid, text) from anon, authenticated;

-- Promoting a connection to be the house one. Deliberately a function rather
-- than a row anybody can UPDATE: this is the switch that starts spending our
-- money, and it should be greppable.
create or replace function set_house_connection(p_connection uuid, p_is_house boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_is_house then
    -- One per provider. Stand the old one down rather than failing on the
    -- index, so moving the house account is one call.
    update connections c
       set is_house = false
     where c.is_house
       and c.provider_id = (select provider_id from connections where id = p_connection);
  end if;
  update connections set is_house = p_is_house where id = p_connection;
  if not found then
    raise exception 'no such connection %', p_connection using errcode = '22023';
  end if;
end;
$$;

revoke execute on function set_house_connection(uuid, boolean) from anon, authenticated;
