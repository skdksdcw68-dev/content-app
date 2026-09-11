-- The things the agent makes, as objects rather than as text in a message.
--
-- A finished research run left its summary on `agent_runs.result` and a copy of
-- the prose in the thread. That is a transcript, not an artefact: nothing could
-- be exported, versioned, previewed or referred to later as "that report", and
-- "export it as a DOCX" had no object for "it" to mean.
--
-- So everything the agent produces -- a research report, a plan, an image, a
-- video, a document, a package -- becomes a row here, and the conversation
-- points at it. Chat renders by `kind`, so a new kind is a new card rather than
-- a new pipeline.
--
-- Two decisions that matter:
--
-- `parent_id` carries derivation. A DOCX made from a report points at the
-- report; a video animated from an image points at the image; version 2 of a
-- plan points at version 1. The source is never modified, so provenance is a
-- walk up this column rather than something reconstructed.
--
-- Cost is stored twice, as estimated and as actual, in the provider's own units
-- (see `Cost` in _shared/connectors/contract.ts). An estimate is never copied
-- into `actual_cost`; a job that finished without the provider saying what it
-- charged leaves actual null, which is the truth.

create table if not exists artifacts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  thread_id   uuid references threads on delete set null,
  run_id      uuid references agent_runs on delete set null,
  brand_id    uuid references brands on delete set null,

  kind        text not null check (kind in
                ('research','plan','campaign','image','video','audio','document','package')),
  title       text not null default '',
  status      text not null default 'ready' check (status in ('pending','ready','failed')),

  version     integer not null default 1,
  parent_id   uuid references artifacts on delete set null,

  -- The file, when there is one. Null for an artefact that is purely structured
  -- content -- a plan preview lives in `body`, a DOCX of it lives in storage.
  storage_path text,
  mime        text,
  byte_size   bigint,

  -- Structured content the card renders: a report's summary and findings, a
  -- plan's preview, a package's manifest. Deliberately jsonb -- each kind has
  -- its own shape and it is read whole, never queried across.
  body        jsonb not null default '{}'::jsonb,

  provider    text,
  model       text,
  estimated_cost jsonb,
  actual_cost    jsonb,

  -- Where a reference asset came from, when this was made from one. The rule
  -- this supports: a reference must never become publishable content by
  -- accident, so derivation is recorded, not inferred.
  source_asset_id uuid references media_assets on delete set null,

  created_at  timestamptz not null default now()
);

create index if not exists artifacts_thread_idx on artifacts (thread_id, created_at desc);
create index if not exists artifacts_user_idx   on artifacts (user_id, created_at desc);

alter table artifacts enable row level security;

-- Readable by the owner; written only by the agent. An artefact the client
-- could write is a result the client could forge -- and exports, versions and
-- publishing all trust these rows.
create policy artifacts_read on artifacts for select to authenticated
  using ((select auth.uid()) = user_id);

grant select on artifacts to authenticated;

-- Makes one, from the agent side.
create or replace function create_artifact(
  p_user   uuid,
  p_kind   text,
  p_title  text,
  p_body   jsonb default '{}'::jsonb,
  p_thread uuid default null,
  p_run    uuid default null,
  p_parent uuid default null,
  p_status text default 'ready'
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_version int := 1;
begin
  -- A new version of something is one more than its parent, so "Plan v3" is
  -- counted rather than guessed.
  if p_parent is not null then
    select coalesce(version, 0) + 1 into v_version from artifacts where id = p_parent;
  end if;

  insert into artifacts (user_id, kind, title, body, thread_id, run_id, parent_id, version, status)
  values (p_user, p_kind, coalesce(p_title, ''), coalesce(p_body, '{}'::jsonb),
          p_thread, p_run, p_parent, v_version, p_status)
  returning id into v_id;

  return v_id;
end $$;

-- Attaches the file once it exists.
create or replace function attach_artifact_file(
  p_artifact uuid, p_path text, p_mime text, p_size bigint
) returns void
language sql
security definer
set search_path = public
as $$
  update artifacts
     set storage_path = p_path, mime = p_mime, byte_size = p_size, status = 'ready'
   where id = p_artifact;
$$;

-- Everything in one conversation, newest first, for rebuilding its cards.
create or replace function thread_artifacts(p_thread uuid)
returns table (
  id uuid, kind text, title text, status text, version int, parent_id uuid,
  storage_path text, mime text, byte_size bigint, body jsonb,
  provider text, model text, estimated_cost jsonb, actual_cost jsonb, created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select a.id, a.kind, a.title, a.status, a.version, a.parent_id,
         a.storage_path, a.mime, a.byte_size, a.body,
         a.provider, a.model, a.estimated_cost, a.actual_cost, a.created_at
    from artifacts a
   where a.thread_id = p_thread
     and a.user_id = (select auth.uid())
   order by a.created_at desc;
$$;

-- One artefact, for a card or a sheet.
create or replace function artifact(p_id uuid)
returns table (
  id uuid, kind text, title text, status text, version int, parent_id uuid,
  storage_path text, mime text, byte_size bigint, body jsonb,
  provider text, model text, estimated_cost jsonb, actual_cost jsonb, created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select a.id, a.kind, a.title, a.status, a.version, a.parent_id,
         a.storage_path, a.mime, a.byte_size, a.body,
         a.provider, a.model, a.estimated_cost, a.actual_cost, a.created_at
    from artifacts a
   where a.id = p_id
     and a.user_id = (select auth.uid());
$$;

revoke execute on function create_artifact(uuid, text, text, jsonb, uuid, uuid, uuid, text) from anon, authenticated, public;
revoke execute on function attach_artifact_file(uuid, text, text, bigint)                 from anon, authenticated, public;
revoke execute on function thread_artifacts(uuid) from anon, public;
revoke execute on function artifact(uuid)         from anon, public;
grant  execute on function thread_artifacts(uuid) to authenticated;
grant  execute on function artifact(uuid)         to authenticated;

-- A bucket for what the agent makes, separate from `media` which holds what
-- gets published. Private: a signed URL is issued per request, so a leaked link
-- expires rather than exposing somebody's research forever.
insert into storage.buckets (id, name, public)
values ('artifacts', 'artifacts', false)
on conflict (id) do nothing;

-- Objects are namespaced `${user_id}/...`, and a person may read only their own
-- folder. Writes go through the service role.
drop policy if exists artifacts_owner_read on storage.objects;
create policy artifacts_owner_read on storage.objects for select to authenticated
  using (bucket_id = 'artifacts' and (storage.foldername(name))[1] = (select auth.uid())::text);
