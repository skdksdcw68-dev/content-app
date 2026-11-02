-- The house ElevenLabs voice (installed 2 Nov 2026 with install-house-generator,
-- key taken from the ELEVENLABS_API_KEY secret) is Autocast's own: a person
-- with no ElevenLabs account asks for a voice and it is made with ours. The
-- card must not say "from your ElevenLabs plan".
update connection_models m
   set metadata = jsonb_set(
         jsonb_set(m.metadata, '{description}', to_jsonb('Speech in Autocast''s voices, any language.'::text)),
         '{cost,basis}', to_jsonb('included with Autocast'::text))
  from connections c
  join providers p on p.id = c.provider_id
 where m.connection_id = c.id
   and c.is_house
   and p.slug = 'elevenlabs'
   and m.capability = 'voice_generation';
