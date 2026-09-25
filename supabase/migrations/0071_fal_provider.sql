-- fal.ai as a provider.
--
-- Abel, 25 Sep 2026: "we buy from cheaper places, higgsfield is bad... i have
-- fal already best match."
--
-- The price comparison is not as one-sided as it sounds and it is worth
-- writing down, because somebody will re-litigate it: Higgsfield's SUBSCRIPTION
-- credits are cheaper per second than fal's per-second rates for the same named
-- models (~$0.034/s against $0.05-$0.22/s). What Higgsfield does not have is
-- headroom -- 3,000 credits a month is roughly ten subscribers, after which the
-- rate gets 40% worse -- or a way to be anything other than a single reseller
-- between us and every model.
--
-- fal bills per second against a card, with no pool to exhaust and no ceiling,
-- so the cost per subscriber stays flat as subscribers are added. One is
-- cheaper at ten customers; the other still works at a thousand. Both are
-- providers now, and `route.ts` picks between them on price per job rather
-- than on anybody's opinion.
insert into providers (slug, name, auth_kind, api_base, docs_url, enabled, featured, tagline)
values (
  'fal',
  'fal.ai',
  'api_key',
  'https://queue.fal.run',
  'https://fal.ai/docs',
  true,
  false,
  'Per-second video, no credit pool'
)
on conflict (slug) do update
  set name      = excluded.name,
      auth_kind = excluded.auth_kind,
      api_base  = excluded.api_base,
      docs_url  = excluded.docs_url,
      enabled   = excluded.enabled,
      tagline   = excluded.tagline;

-- The account Autocast's own generators hang off.
--
-- A real row rather than a throwaway, because deleting the user would cascade
-- the connection and the house generator with it -- which is exactly how a
-- probe account took a working connection down once already. Nothing signs in
-- as this; it exists to own connections that `is_house` then shares.
comment on column public.connections.is_house is
  'Autocast''s own generator: usable by every signed-in person, metered against plans_catalog. Owned by the house account, which is never signed into.';
