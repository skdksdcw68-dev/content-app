-- The logo the app asks for and can actually use.
--
-- Abel, 25 Sep 2026: "on the same page, 'your name or your logo' -- so when the
-- user hits that, the user goes and again goes, but the user is never asked to
-- upload his logo... this is what makes the app terrible."
--
-- He was right, and it was worse than a missing screen: "Your name or logo" was
-- an option in the series flow that NOTHING could deliver. There was no field
-- on `brands`, no image picker outside the chat, and no bucket to put one in.
-- Picking it appended a sentence to a text brief and was then forgotten.
alter table public.brands
  add column if not exists logo_path text;

comment on column public.brands.logo_path is
  'Object path in the `brand` bucket, namespaced <user_id>/<brand_id>/logo.<ext>. Handed to the video generator so a series can actually put the mark on the video.';

-- Its own bucket, private like `artifacts`. Not `media`: that holds what gets
-- published, and a logo is an input rather than an output. Private because a
-- brand's mark before launch is not something to leave on a public URL.
insert into storage.buckets (id, name, public, file_size_limit)
values ('brand', 'brand', false, 5 * 1024 * 1024)
on conflict (id) do update set file_size_limit = excluded.file_size_limit;

-- Objects are namespaced `${user_id}/...`, exactly as artifacts are, so the
-- same folder rule decides who may touch them. Unlike artifacts, the owner
-- writes here directly -- they are choosing a file from their own phone, and
-- routing that through an Edge Function would buy nothing.
drop policy if exists brand_owner_read on storage.objects;
create policy brand_owner_read on storage.objects for select to authenticated
  using (bucket_id = 'brand' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists brand_owner_write on storage.objects;
create policy brand_owner_write on storage.objects for insert to authenticated
  with check (bucket_id = 'brand' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists brand_owner_update on storage.objects;
create policy brand_owner_update on storage.objects for update to authenticated
  using (bucket_id = 'brand' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists brand_owner_delete on storage.objects;
create policy brand_owner_delete on storage.objects for delete to authenticated
  using (bucket_id = 'brand' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Saving it. Security definer so the column can stay closed to direct writes,
-- and so "whose brand is this" is decided here rather than trusted.
create or replace function set_brand_logo(p_brand uuid, p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := (select auth.uid());
begin
  if v_user is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if not exists (select 1 from brands b where b.id = p_brand and b.user_id = v_user) then
    raise exception 'that brand is not yours' using errcode = '42501';
  end if;

  -- Nulling it is how a logo is removed, so an empty string means the same.
  update brands
     set logo_path = nullif(btrim(coalesce(p_path, '')), '')
   where id = p_brand;
end $$;

revoke execute on function set_brand_logo(uuid, text) from anon, public;
grant  execute on function set_brand_logo(uuid, text) to authenticated;
