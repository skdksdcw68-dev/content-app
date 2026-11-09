-- 0107: the master prompts live on the server (Abel, 9 Nov 2026: "the server saves
-- this workflow ... whenever the user makes a video, the app uses the master
-- prompt workflow").
--
-- One row per prompt. The code keeps the same text as a fallback, so a missing
-- or disabled row never stops a video; changing a row changes every video made
-- after it (the functions cache a prompt for about a minute).
--
--   story_planner   the script master prompt for every picture story
--                   (with {{...}} slots the code fills from the length and style)
--   picture_prompt  how each scene's picture prompt is assembled
--   picture_checker the reviewer that looks at every picture
--   glow_writer     the Glow explainer's writer
--   showdown_writer the Stickman showdown's writer
--
-- Per-format knowledge (playbooks, the writer model, the narrator) stays in
-- content_templates.workflow (writer_model, voice_id, playbook).

create table if not exists public.master_prompts (
  key        text primary key,
  body       text not null,
  notes      text,
  enabled    boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.master_prompts enable row level security;
-- No policies: only the server (service role) reads or writes them.
