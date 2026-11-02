-- ElevenLabs as a provider a person can connect with a pasted key (Abel, 2 Nov
-- 2026: "when I pass a key from ElevenLabs, it doesn't know or it doesn't
-- work"). The adapter is `_shared/connectors/elevenlabs.ts`; the key arrives
-- through `connect-generator` and is sealed to its own connection row.
--
-- Not featured: nobody is offered a sign-in button for it, because there is no
-- sign-in -- the door is the chat, where a pasted key is recognised.
insert into providers (slug, name, auth_kind, api_base, enabled, featured, tagline)
values ('elevenlabs', 'ElevenLabs', 'api_key', 'https://api.elevenlabs.io/v1', true, false, 'Speech in your own ElevenLabs voices')
on conflict (slug) do update
  set api_base = excluded.api_base, enabled = true, auth_kind = 'api_key';
