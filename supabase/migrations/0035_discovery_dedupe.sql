-- A discovery with the same model in it twice must not lose every model.
--
-- Abel's first real Higgsfield sign-in reported 101 tools and recorded zero
-- models. The adapter listed the audio catalogue under both audio and voice, so
-- one model id appeared twice in a single insert, and `on conflict do update`
-- refuses to touch a row twice in one statement ("cannot affect row a second
-- time"). The whole list was rejected, the caller did not read the error, and
-- the account said "connected, nothing available".
--
-- The adapter no longer sends duplicates. This makes the database indifferent
-- to them anyway: one row per model id, the first-ranked occurrence winning.

create or replace function record_discovery(p_connection uuid, p_models jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer := 0;
begin
  if jsonb_typeof(p_models) <> 'array' then
    raise exception 'models must be an array' using errcode = '22023';
  end if;

  update connection_models set available = false where connection_id = p_connection;

  insert into connection_models (connection_id, capability, external_id, label, metadata, rank, available, last_seen_at)
  select distinct on (m->>'external_id')
         p_connection,
         m->>'capability',
         m->>'external_id',
         coalesce(nullif(m->>'label', ''), m->>'external_id'),
         coalesce(m->'metadata', '{}'::jsonb),
         least(coalesce((m->>'rank')::int, 100), 32767)::smallint,
         true,
         now()
    from jsonb_array_elements(p_models) with ordinality as e(m, position)
   where m->>'capability' is not null
     and m->>'external_id' is not null
     -- A capability nobody declared is dropped rather than inserted: the agent
     -- switches on this vocabulary, so an adapter inventing one at runtime
     -- would produce rows nothing can route to.
     and exists (select 1 from capabilities c where c.slug = m->>'capability')
   order by m->>'external_id', position
  on conflict (connection_id, external_id) do update
    set capability   = excluded.capability,
        label        = excluded.label,
        metadata     = excluded.metadata,
        rank         = excluded.rank,
        available    = true,
        last_seen_at = now();

  get diagnostics v_count = row_count;

  -- The capability list follows from the models, so it can never disagree with
  -- them -- a connection claiming video_generation with no video model is a
  -- promise the agent would act on and then fail to keep.
  delete from connection_capabilities where connection_id = p_connection;
  insert into connection_capabilities (connection_id, capability)
  select distinct connection_id, capability
    from connection_models
   where connection_id = p_connection and available
  on conflict do nothing;

  return v_count;
end $$;

revoke execute on function record_discovery(uuid, jsonb) from anon, authenticated, public;
