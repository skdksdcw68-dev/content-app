-- An even number of styles, so the two-column grid never ends on a stranded
-- tile (Abel, 24 Sep 2026: "on that page i want it to make the content
-- choosing which can be devided by 2").
--
-- 37 was odd. Rather than invent a 38th style with no photograph -- the exact
-- thing he objected to the day before -- the most redundant one steps out.
-- "Stoic mind" (Old ideas for today) sat in Mindset beside "Quotes and
-- thoughts" (A line worth remembering) and "Motivation"; three styles were
-- covering one idea.
--
-- Disabled, not deleted: the brief, pillars and workflow are still here, and
-- any plan already written from it keeps working. Re-enabling it is one line,
-- and whoever does must add or retire another to keep the count even.
update public.content_templates
   set enabled = false
 where slug = 'stoic';

-- Guard rail for the next person: the app's picker is two columns wide.
comment on column public.content_templates.enabled is
  'Shown in the picker. Keep the number of enabled rows EVEN -- the picker is a two-column grid and an odd count leaves a stranded tile (Abel, 24 Sep 2026).';
