-- A series remembers WHICH voice speaks and how its words show.
--
-- Abel, 31 Oct 2026: "the user chooses the caption style and every single
-- thing first, and when he finishes the onboarding, we will move. He will
-- need to choose the caption style, the voiceover, and things like this."
-- And, hearing a paid ElevenLabs voice next to free ones: "it's clear the
-- paid is better."
--
-- `voice` (0075) is a sentence for the writer -- "a deep, authoritative male
-- voice". The renderer needs the actual ElevenLabs voice that says it, and the
-- caption style it burns the words in with. Both are chosen in Start a series
-- and live on the plan, because a series writes one post at a time and every
-- later post is made the same way.
--
-- 🔴 Apply this BEFORE deploying the propose-plan that writes these columns:
-- an insert naming a column that does not exist fails, and with it every new
-- series.
--
-- Nullable: every series made before this has neither, and renders as it did.
alter table public.content_plans
  add column if not exists voice_id      text,
  add column if not exists caption_style text;

alter table public.content_plans drop constraint if exists content_plans_caption_style_check;
alter table public.content_plans
  add constraint content_plans_caption_style_check
  check (caption_style is null or caption_style in ('bold_pop', 'highlight', 'minimal', 'subtitle', 'boxed', 'none'));
