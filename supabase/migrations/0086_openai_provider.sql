-- OpenAI's own Images API as a house generator (Netro, 19 Oct 2026: "why don't
-- we use the GPT 2 model inside the OpenAI API? No fal needed for that, and we
-- get it for a discount too.").
--
-- A provider row like fal's: enabled so a connection can be begun for the house
-- account, not featured so no customer is offered it. The adapter is
-- `_shared/connectors/openai.ts`; the connection itself is installed with
-- `install-house-generator` and marked house.
insert into providers (slug, name, auth_kind, api_base, enabled, featured, tagline)
values ('openai', 'OpenAI', 'api_key', 'https://api.openai.com/v1', true, false, 'GPT Image 2, straight from OpenAI')
on conflict (slug) do update
  set api_base = excluded.api_base, enabled = true, auth_kind = 'api_key';
