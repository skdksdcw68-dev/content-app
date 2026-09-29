-- A series remembers how it looks and sounds.
--
-- Abel, 29 Sep 2026, walking through Start a series: after the platform and the
-- seconds "it should ask me for the video style it wants with pictures. I must
-- put that... and then something that asks me for a voiceover. It must be a
-- requirement."
--
-- Both used to be one checkbox each in a list ("A voiceover") that was written
-- into the brief and could be skipped. They are questions of their own now, and
-- a series writes ONE post at a time -- the next is written once this one is
-- out (`extendSeriesIfNeeded`) -- so whatever was chosen has to live on the
-- plan, not in the head of the screen that started it. These three columns are
-- what the next post is written from.
--
-- Free text, one line each, cleaned by `propose-plan` before it lands here.
-- Nullable: every series made before this has none, and writes exactly as it
-- did.
alter table public.content_plans
  add column if not exists look     text,
  add column if not exists voice    text,
  add column if not exists language text;
