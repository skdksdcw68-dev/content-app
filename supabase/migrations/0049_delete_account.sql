-- 0049: make "Delete account" actually able to delete.
--
-- Nearly every table cascades from auth.users, but a few link to each other
-- with RESTRICT (a post can't lose the consent it went out under, a video in a
-- post can't vanish). Inside the one big cascade those fire before their
-- parents are gone and the whole delete is refused. This clears exactly those
-- rows, in an order that satisfies them, so auth.admin.deleteUser can finish.
--
-- Service role only: the delete-account function calls it just before
-- deleting the user, never the app directly.

create or replace function clear_account_links(p_user uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from post_assets
   where post_target_id in (select id from post_targets where user_id = p_user);
  update post_targets set consent_id = null
   where user_id = p_user and consent_id is not null;
  delete from consent_records where user_id = p_user;
  delete from post_targets where user_id = p_user;
end $$;
revoke execute on function clear_account_links(uuid) from anon, authenticated, public;
