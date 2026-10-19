-- "new row violates row-level security policy" on every picture upload.
--
-- Netro, 19 Oct 2026 (build 107): uploading a picture anywhere shows the
-- violation. Swift writes UUIDs UPPERCASE (UUID.uuidString); Postgres writes
-- auth.uid()::text lowercase. The owner-folder rule compared them as plain
-- text, so a path built from an uppercase id never matched -- the profile
-- photo and the brand logo were refused for everyone.
--
-- The app now lowercases its paths, and the policies compare case-blind so
-- builds already installed (107 and older) work too.

drop policy if exists brand_owner_read on storage.objects;
create policy brand_owner_read on storage.objects for select to authenticated
  using (bucket_id = 'brand' and lower((storage.foldername(name))[1]) = (select auth.uid())::text);

drop policy if exists brand_owner_write on storage.objects;
create policy brand_owner_write on storage.objects for insert to authenticated
  with check (bucket_id = 'brand' and lower((storage.foldername(name))[1]) = (select auth.uid())::text);

drop policy if exists brand_owner_update on storage.objects;
create policy brand_owner_update on storage.objects for update to authenticated
  using (bucket_id = 'brand' and lower((storage.foldername(name))[1]) = (select auth.uid())::text);

drop policy if exists brand_owner_delete on storage.objects;
create policy brand_owner_delete on storage.objects for delete to authenticated
  using (bucket_id = 'brand' and lower((storage.foldername(name))[1]) = (select auth.uid())::text);

drop policy if exists artifacts_owner_read on storage.objects;
create policy artifacts_owner_read on storage.objects for select to authenticated
  using (bucket_id = 'artifacts' and lower((storage.foldername(name))[1]) = (select auth.uid())::text);

drop policy if exists artifacts_owner_upload on storage.objects;
create policy artifacts_owner_upload on storage.objects for insert to authenticated
  with check (
    bucket_id = 'artifacts'
    and lower((storage.foldername(name))[1]) = (select auth.uid())::text
    and (storage.foldername(name))[2] = 'uploads'
  );

-- The avatar RPC had the same case-sensitive check.
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
  if v_path is not null and lower(split_part(v_path, '/', 1)) <> v_user::text then
    raise exception 'that picture is not yours' using errcode = '42501';
  end if;
  insert into profiles (user_id, avatar_path)
  values (v_user, v_path)
  on conflict (user_id) do update set avatar_path = excluded.avatar_path;
end $$;
