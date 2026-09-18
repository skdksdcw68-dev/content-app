-- 0046: the editor's music library.
--
-- Tracks come from Openverse (Creative Commons audio, mostly Jamendo), limited
-- to CC0, public domain and CC BY: licences that allow commercial use AND
-- putting music under a video. BY-ND forbids the video; BY-SA would force the
-- whole post under the same licence. Openverse allows 200 anonymous requests a
-- day, so answers are cached here for six hours.

create table if not exists music_cache (
  key        text primary key,
  body       jsonb not null,
  fetched_at timestamptz not null default now()
);

alter table music_cache enable row level security;
-- No policies: only the edge function (service role) reads or writes it.
