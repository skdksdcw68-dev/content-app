-- 0057: a series -- pick a content style, and it makes and posts in it.
--
-- Abel, 23 Sep 2026: "there is a content inspo, a lot actually... they
-- choose the style... they will be asked to connect TikTok, YouTube and IG...
-- the duration, or they hit decide for me... every day it will generate the
-- content they chose and it posts for them. We use GitHub repos to get the
-- same kind of feel that we use a template to do a website."
--
-- A style is a template: a brief the writer works from, the themes it
-- rotates between, and how the video should look. Choosing one makes an
-- ordinary plan through propose-plan, so everything downstream -- slots,
-- rendering the day before, the approval tap, the scheduler -- is what
-- already runs. The plan remembers which style it came from and how long
-- each video should be.

create table if not exists content_templates (
  slug         text primary key,
  name         text not null,
  tagline      text not null,
  category     text not null,
  -- What the writer is told the month is about.
  brief        text not null,
  -- The themes, as [{name, detail}]. Created as the brand's pillars when
  -- the style is chosen, so slots rotate through them.
  pillars      jsonb not null default '[]',
  -- How every video should look, added to the writer's shot instructions.
  visual_style text not null default '',
  -- An SF Symbol for the tile until there is a picture; the picture's
  -- asset name, made by Abel, once there is one.
  symbol       text not null default 'sparkles',
  art          text,
  sort         integer not null default 100,
  enabled      boolean not null default true,
  created_at   timestamptz not null default now()
);

alter table content_templates enable row level security;
drop policy if exists content_templates_read on content_templates;
create policy content_templates_read on content_templates for select to authenticated using (enabled);
grant select on content_templates to authenticated;

alter table content_plans add column if not exists template_slug text references content_templates on delete set null;
alter table content_plans add column if not exists duration_s integer;

insert into content_templates (slug, name, tagline, category, brief, pillars, visual_style, symbol, sort) values
  ('scary', 'Scary stories', 'Short, unsettling, a twist at the end.', 'Stories',
   'Short scary stories, urban legends and unsettling true facts, told calmly, each ending on a twist or an open question.',
   '[{"name":"Urban legends","detail":"A legend told as if it happened last week."},{"name":"True-crime facts","detail":"One real, documented case in 40 seconds."},{"name":"Things that do not add up","detail":"A mystery with no clean explanation."},{"name":"Two-sentence horror","detail":"Set-up, then the line that turns it."}]',
   'dark and moody, slow push-ins, dim interiors and empty night streets, high contrast, film grain, no faces in focus', 'moon.stars', 10),
  ('motivation', 'Motivation', 'Discipline, small wins, hard truths.', 'Mindset',
   'Motivation for people building something: discipline over mood, small daily wins, hard truths said kindly, and routines that hold.',
   '[{"name":"Discipline","detail":"Doing it on the days you do not feel like it."},{"name":"Small wins","detail":"One thing done today."},{"name":"Hard truths","detail":"The uncomfortable line, said plainly."},{"name":"Morning routines","detail":"The first hour."}]',
   'cinematic, sunrise and golden hour, gym floors, running at dawn, city rooftops, warm light, slow steady camera', 'flame', 20),
  ('facts', 'Did you know', 'Surprising facts, told fast.', 'Learning',
   'Surprising, checkable facts about the world, told fast with one clear image per fact, ending on the detail nobody expects.',
   '[{"name":"Surprising facts","detail":"One fact, one image, one payoff."},{"name":"History in 30 seconds","detail":"An event, compressed."},{"name":"Science you can feel","detail":"Something physical you can try."},{"name":"Numbers that surprise","detail":"A figure and what it means."}]',
   'clean b-roll, close-ups of real objects, satisfying macro shots, bright even light, no text on screen', 'lightbulb', 30),
  ('product', 'Show the product', 'Demos, before and after, behind the scenes.', 'Business',
   'Show what the product does and who it is for: demos, a problem it solves, before and after, and honest behind-the-scenes.',
   '[{"name":"Demo","detail":"One feature, start to finish."},{"name":"Before and after","detail":"The same task, without and with."},{"name":"A problem it solves","detail":"Start from the annoyance."},{"name":"Behind the scenes","detail":"How it is actually made."}]',
   'clean studio product shots, hands using the product, bright even light, neutral backgrounds, shallow depth of field', 'shippingbox', 40),
  ('dayinlife', 'Day in the life', 'Real days, one small thing at a time.', 'Lifestyle',
   'A day in the life of the person behind the account: mornings, work, evenings, and one small thing that made the day.',
   '[{"name":"Morning","detail":"How the day starts."},{"name":"Work","detail":"The middle of it, honestly."},{"name":"Evening","detail":"Winding down."},{"name":"One small thing","detail":"The detail that made today."}]',
   'handheld point-of-view, natural light, real rooms and streets, unpolished, warm', 'sun.max', 50),
  ('tips', 'Tips and tricks', 'One trick per video.', 'Learning',
   'Practical tips in the account''s field: one trick per video, mistakes to avoid, tools worth knowing, and shortcuts that hold up.',
   '[{"name":"One trick","detail":"A single move, shown."},{"name":"Mistakes to avoid","detail":"What people get wrong."},{"name":"Tools","detail":"One tool, one use."},{"name":"Shortcuts","detail":"The faster way."}]',
   'clean desk and hands, over-the-shoulder shots, bright and simple, quick cuts', 'wrench.and.screwdriver', 60),
  ('myths', 'Myth busting', 'What people believe, and what is true.', 'Learning',
   'Common myths in the account''s field and what is actually true, said plainly with one reason each.',
   '[{"name":"Common myths","detail":"The belief, then the fact."},{"name":"What actually works","detail":"The thing that does."},{"name":"Ask the expert","detail":"A question people keep asking."}]',
   'clean backdrops, split scenes, direct to camera, bright even light', 'xmark.seal', 70),
  ('storytime', 'Story time', 'Something that happened, and what it taught.', 'Stories',
   'Personal stories from the account: something that happened, the turning point, and the lesson, told to one person.',
   '[{"name":"Something that happened","detail":"A moment, told straight."},{"name":"Lessons learned","detail":"What it changed."},{"name":"The turning point","detail":"The day it turned."}]',
   'warm interior, one subject talking, soft window light, intimate framing', 'book', 80),
  ('compare', 'This vs that', 'Two options, one honest verdict.', 'Learning',
   'Comparisons in the account''s field: two options side by side, cheap against expensive, then against now, with a verdict.',
   '[{"name":"Two options","detail":"A and B, honestly."},{"name":"Cheap vs expensive","detail":"Where the money goes."},{"name":"Then vs now","detail":"How it changed."}]',
   'side-by-side and split-screen compositions, matching angles, clean backgrounds', 'scalemass', 90),
  ('quotes', 'Quotes and thoughts', 'A line worth remembering.', 'Mindset',
   'Short thoughts and quotes worth remembering, one per video, with a sentence on why it matters today.',
   '[{"name":"A line worth remembering","detail":"One sentence, held."},{"name":"Stoic thoughts","detail":"Old ideas for today."},{"name":"Words for today","detail":"Something to carry."}]',
   'slow landscapes, ocean and sky, minimal and calm, long takes, soft light', 'quote.bubble', 100),
  ('luxury', 'Luxury lifestyle', 'Cars, homes, travel, habits.', 'Lifestyle',
   'Aspirational lifestyle: cars, homes, travel and the habits behind them, shown rather than bragged.',
   '[{"name":"Cars","detail":"One car, one detail."},{"name":"Homes","detail":"A room worth seeing."},{"name":"Travel","detail":"A place, at its best hour."},{"name":"Habits of the rich","detail":"What they actually do."}]',
   'glossy, golden hour, slow gimbal moves, reflections, polished surfaces', 'crown', 110),
  ('pets', 'Pets and animals', 'Funny, cute, and a fact or two.', 'Lifestyle',
   'Pets and animals: funny moments, facts about animals, and small cute wins, kept light.',
   '[{"name":"Funny moments","detail":"The thing it did."},{"name":"Facts about animals","detail":"One fact, one animal."},{"name":"Cute wins","detail":"A small good moment."}]',
   'bright, playful, close-ups at animal eye level, natural light', 'pawprint', 120)
on conflict (slug) do nothing;

-- The render loop needs the video length the series asked for. Returned
-- columns change, so the function is dropped first (42P13).
drop function if exists due_for_render(int);
create function due_for_render(p_limit int default 10)
returns table (post_id uuid, user_id uuid, brand_id uuid, prompt text, duration_s integer)
language sql
security definer
set search_path = public
as $$
  select p.id, p.user_id, p.brand_id,
         case when btrim(p.concept) <> '' then p.concept else p.hook end,
         c.duration_s
    from posts p
    join brand_settings s on s.brand_id = p.brand_id
    left join content_plans c on c.id = p.plan_id
   where p.status = 'scheduled'
     and p.render_after is not null
     and p.render_after <= now()
     and p.media_strategy = 'generate'
     and s.is_on
     and s.publishing_on
     and not exists (
       select 1 from generation_jobs g
        where g.post_id = p.id
          and g.status in ('queued','submitted','running','succeeded')
     )
   order by p.scheduled_for
   limit p_limit;
$$;
revoke execute on function due_for_render(int) from anon, authenticated, public;
