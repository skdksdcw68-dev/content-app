-- A sample video for every format, so it can be watched before it is picked
-- (Abel, 5 Nov 2026: "make sure the user can directly open the video and see
-- the preview"). The files live in a public bucket of their own; the app keeps
-- the same three built in and the server's link wins when there is one.
insert into storage.buckets (id, name, public)
values ('samples', 'samples', true)
on conflict (id) do update set public = true;

alter table public.content_templates add column if not exists preview_url text;
