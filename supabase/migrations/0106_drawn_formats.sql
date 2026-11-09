-- 0106: two code-drawn formats and the music library they use (Abel, 8 Nov 2026,
-- from the viral references he sent).
--
--  * `stickman`  Stickman Showdown: white stick figures with bold labels do
--    pull-ups, tire and drop one by one; the music drops and the last figure,
--    never shown before, is revealed. 20 s, vertical, no voice.
--  * `explainer` Glow Explainer: a calm narrator over little glowing worlds
--    (a hill and a flag, a night town, a globe, a staircase, a phone feed...),
--    16:9, a new picture every 5 to 8 s. About 70 s, longer on request.
--
-- Neither uses a picture or video model: the writer plans, the voice is
-- recorded, and the Fly renderer DRAWS the frames (renderer/draw). The run
-- is an ordinary story run; `workflow.engine = "drawn"` sends it to
-- run-agent-jobs/drawn.ts instead of the picture pipeline.
--
-- Saved HIDDEN (enabled = false) and switched on after a real end-to-end video
-- and the renderer image that can draw them is deployed.

insert into content_templates (slug, name, tagline, category, brief, pillars, visual_style, symbol, sort, enabled, workflow) values
('stickman', 'Stickman showdown', 'Stick figures fight to the last rep. One never quits.', 'Motivation',
 'A 16 to 20 second vertical motivational video drawn in code: white stick figures with one bold word each take on a physical challenge the writer designs fresh every time (squats, carrying a box, a wall sit, running...), tire and drop one by one; when the music drops, a last figure nobody saw is revealed, still going. No voice, no captions; only the words and the challenge change. It cannot be longer.',
 '[{"name":"What runs out","detail":"Motivation, ego, hype, talent: the things most people rely on."},{"name":"What lasts","detail":"Discipline, consistency, obsession: the one left standing."},{"name":"Your niche","detail":"The same contest with the words of your audience."}]',
 'white stick figures on pure black, bold upper-case labels, red on the straining joints, no voice, music with a drop',
 'figure.strengthtraining.traditional', 12, false,
 '{"format":"drawn","engine":"drawn","drawn":"showdown","voice":"none","text":"none","music":"phonk with a drop","duration_s":20,"steps":["Choose the words","Draw the showdown","Add music","Post"]}'),
('explainer', 'Glow explainer', 'One idea, explained over glowing little worlds.', 'Motivation',
 'A calm narrator explains one counter-intuitive idea about money, mindset or your niche while a world is drawn in white line and glow: a person with an idea, a hill and a flag, a night town, a globe, a staircase, a phone feed, a machine of gears. 16:9, fast and smooth.',
 '[{"name":"The counter-intuitive claim","detail":"A sentence that stops the scroll."},{"name":"Imagine someone","detail":"A small story that makes it real."},{"name":"What they cannot see","detail":"The mechanism behind it."},{"name":"The reframe","detail":"One last line that sticks."}]',
 'black screen, faint dot grid, glowing white line art and silhouettes, small pill labels, numbers that count up, a camera that never rests',
 'sparkles', 13, false,
 '{"format":"drawn","engine":"drawn","drawn":"glow","voice":"narration","text":"none","music":"soft ambient bed","duration_s":70,"steps":["Write the script and plan the scenes","Record the voiceover","Draw the scenes in time with the words","Add music","Post"]}')
on conflict (slug) do update set
  name = excluded.name, tagline = excluded.tagline, category = excluded.category, brief = excluded.brief,
  pillars = excluded.pillars, visual_style = excluded.visual_style, symbol = excluded.symbol,
  sort = excluded.sort, workflow = excluded.workflow;

-- Royalty-free music with its drop measured in advance, so the stickman's
-- reveal can land on it. Files live in the `artifacts` bucket under music/.
create table if not exists public.drawn_music (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  path       text not null unique,
  formats    text[] not null default '{}',
  -- Seconds into the file where the bass hits hard after the build-up.
  drop_s     numeric,
  -- Where a bed starts when there is no drop to line up (seconds into the file).
  start_s    numeric not null default 0,
  gain_db    numeric,
  bpm        numeric,
  source     text,
  license    text not null,
  enabled    boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.drawn_music enable row level security;
-- No policies: only the server (service role) reads or writes the library.
