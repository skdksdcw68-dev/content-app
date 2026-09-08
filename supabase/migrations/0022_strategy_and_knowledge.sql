-- Understand before you spend.
--
-- The rule this exists to enforce, in Abel's words:
--
--   UNDERSTAND -> CLARIFY -> CONFIRM -> REASON -> PRODUCE
--   not
--   USER TYPES SOMETHING -> SPEND MONEY -> HOPE IT WAS RIGHT
--
-- Two pieces. `brand_knowledge()` answers "what do I already know", so the
-- agent asks about the three things it is missing rather than the eleven it
-- could ask about -- questions you already answered are the fastest way to make
-- something feel stupid, and every one costs a round trip. And `strategies`
-- gives the plan something to be approved *before* thirty days of content are
-- written, which is the expensive mistake this whole file is about: generating
-- a month and then discovering the goal was wrong.

-- What the agent is working towards, agreed before anything is produced.
--
-- Deliberately small. Everything here is a decision a person would recognise
-- as theirs -- the goal, the appetite for risk, the mix -- and nothing here is
-- a model's opinion dressed as configuration.
create table if not exists strategies (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users on delete cascade,
  brand_id    uuid not null references brands on delete cascade,
  thread_id   uuid references threads on delete set null,

  -- The answers that were asked for. Nullable because a strategy is written
  -- before it is complete and filled in as the conversation goes.
  goal        text check (goal in ('followers','customers','awareness','launch','other')),
  appetite    text check (appetite in ('conservative','balanced','aggressive')),
  audience    text not null default '',
  cadence     smallint,

  -- The reasoning, in the agent's words, for the person to read and argue with.
  summary     text not null default '',
  -- [{pillar, share}] adding to 100. Kept as json rather than rows: it is read
  -- and written whole, never queried across, and a five-row table for a thing
  -- with one owner is a join for nothing.
  pillar_mix  jsonb not null default '[]'::jsonb,

  -- Nothing is produced from a strategy until this is set. The whole point.
  approved_at timestamptz,
  superseded_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists strategies_brand_idx on strategies (brand_id, created_at desc);

create trigger strategies_touch before update on strategies
  for each row execute function touch_updated_at();

alter table strategies enable row level security;

-- Readable by its owner, and written only through the agent. A client that
-- could set `approved_at` itself would make approval a formality.
create policy strategies_read on strategies
  for select using ((select auth.uid()) = user_id);

comment on table strategies is
  'What the agent is working towards. Approved by a person before any content is generated from it -- see 0022 for why.';

-- What is known about a brand, and what is missing.
--
-- Returned as one row of booleans rather than the values themselves: the agent
-- needs to decide what to ask, and handing it the whole brand to reason over is
-- both more tokens and more room to be wrong. The values it actually needs come
-- from the reads it already does.
create or replace function brand_knowledge(p_brand uuid)
returns table (
  brand_id        uuid,
  has_niche       boolean,
  has_audience    boolean,
  fact_count      integer,
  pillar_count    integer,
  published_count integer,
  has_metrics     boolean,
  has_generator   boolean,
  has_connection  boolean,
  posts_per_day   smallint,
  strategy_id     uuid,
  strategy_approved boolean
)
language sql
security definer
set search_path = public
as $$
  select
    b.id,
    btrim(coalesce(b.niche, '')) <> '',
    btrim(coalesce(b.audience, '')) <> '',
    (select count(*)::int from brand_memory m where m.brand_id = b.id),
    (select count(*)::int from content_pillars c where c.brand_id = b.id),
    (select count(*)::int from posts p where p.brand_id = b.id and p.status = 'posted'),
    -- Numbers live on the target, not the post: one post fans out to N
    -- accounts and each is measured where it was published.
    exists (
      select 1 from post_targets t
        join posts p on p.id = t.post_id
       where p.brand_id = b.id and t.metrics_at is not null
    ),
    exists (
      select 1 from private.provider_credentials g
       where g.user_id = b.user_id and g.revoked_at is null
         and octet_length(g.secret_ct) > 0
    ),
    exists (
      select 1 from platform_connections c
       where c.brand_id = b.id and c.status = 'active'
    ),
    s.posts_per_day,
    latest.id,
    latest.approved_at is not null
  from brands b
  left join brand_settings s on s.brand_id = b.id
  left join lateral (
    select st.id, st.approved_at
      from strategies st
     where st.brand_id = b.id and st.superseded_at is null
     order by st.created_at desc
     limit 1
  ) latest on true
  where b.id = p_brand;
$$;

revoke execute on function brand_knowledge(uuid) from anon, public;
grant  execute on function brand_knowledge(uuid) to authenticated;
