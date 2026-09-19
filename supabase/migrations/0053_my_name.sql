-- 0053: the person's own name.
--
-- Abel, 19 Sep 2026: the account is the person, not their TikTok or YouTube.
-- Onboarding asks "What should we call you?" and Profile shows that, with the
-- initial as the picture. profiles already exists (user_id, display_name) but
-- the app could only read and update it, never create its row -- this is the
-- one way in.

create or replace function set_my_name(p_name text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_name text := nullif(left(btrim(coalesce(p_name, '')), 60), '');
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  insert into profiles (user_id, display_name)
  values (auth.uid(), v_name)
  on conflict (user_id) do update set display_name = excluded.display_name;
end $$;
revoke execute on function set_my_name(text) from anon, public;
grant execute on function set_my_name(text) to authenticated;
