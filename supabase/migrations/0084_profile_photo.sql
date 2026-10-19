-- A profile picture.
--
-- Netro, 19 Oct 2026: "When a user opens their profile and clicks the edit
-- button, there is no separate page or sheet to edit the profile picture and
-- name, or to view email and detailed account information." The name was a
-- one-field alert and there was nowhere to keep a picture.
--
-- Stored in the private `brand` bucket (0065) at `<user_id>/avatar.jpg`, so
-- the same owner-folder policies decide who may touch it. The PATH is kept,
-- never a URL: a signed link expires.

alter table public.profiles
  add column if not exists avatar_path text;

create or replace function public.set_my_avatar(p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := (select auth.uid());
  v_path text := nullif(btrim(coalesce(p_path, '')), '');
begin
  if v_user is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  -- Only a path in their own folder; anything else is not theirs to point at.
  if v_path is not null and split_part(v_path, '/', 1) <> v_user::text then
    raise exception 'that picture is not yours' using errcode = '42501';
  end if;
  insert into profiles (user_id, avatar_path)
  values (v_user, v_path)
  on conflict (user_id) do update set avatar_path = excluded.avatar_path;
end $$;

revoke execute on function public.set_my_avatar(text) from anon, public;
grant  execute on function public.set_my_avatar(text) to authenticated;
