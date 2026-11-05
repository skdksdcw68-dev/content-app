-- Keeps the chat function warm (Abel, 5 Nov 2026: "Claude replies in under a
-- second, mine takes ten"). The first message after a quiet spell waited 3 to 5
-- seconds while the function started from cold. A GET every minute starts it
-- and is turned away at once ("POST only"), so a real message finds it ready.
--
-- The URL and the anon key are set outside this file (the key is public, but
-- keys stay out of the repo): update private.scheduler_config set chat_url =
-- '.../functions/v1/agent-chat', anon_key = '<anon key>'.
alter table private.scheduler_config add column if not exists chat_url text;
alter table private.scheduler_config add column if not exists anon_key text;

create or replace function private.keep_chat_warm() returns void
language plpgsql security definer set search_path = '' as $$
declare
  cfg record;
begin
  select chat_url, anon_key into cfg from private.scheduler_config where id limit 1;
  if cfg.chat_url is null or cfg.anon_key is null then return; end if;
  perform net.http_get(
    url := cfg.chat_url,
    headers := jsonb_build_object('Authorization', 'Bearer ' || cfg.anon_key),
    timeout_milliseconds := 5000
  );
end $$;

select cron.schedule('keep-chat-warm', '* * * * *', 'select private.keep_chat_warm()');
