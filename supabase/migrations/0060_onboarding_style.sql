-- The content style chosen during onboarding.
--
-- Abel, 24 Sep 2026: "make the onboarding of choosing a content". Picking the
-- kind of videos is the decision the whole product turns on, so it is made on
-- day one rather than the first time somebody opens the series flow. Stored on
-- the brand, not the phone, so it survives a reinstall and a second device --
-- the same reason `Brand.answeredOnboarding` is a server fact.
--
-- It is a hint, never a constraint: `content_plans.template_slug` (0057) stays
-- the record of what a given plan was actually written from. This only says
-- what to offer first.
alter table public.brand_settings
  add column if not exists style_slug text;

comment on column public.brand_settings.style_slug is
  'content_templates.slug chosen during onboarding. Pre-selects the series flow; the plan''s own template_slug is what a plan was written from.';

-- Not a foreign key on purpose: the catalogue is editable (0058 upserts it),
-- and a style being retired must never block somebody''s settings from saving.
-- An unknown slug simply fails to match and nothing is pre-selected.
