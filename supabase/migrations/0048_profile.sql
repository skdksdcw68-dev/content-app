-- 0048: what the new Profile needs from the database.
--
--   disconnect_connection  forget a platform account: status revoked, stored
--                          tokens deleted. (The edge function revokes them at
--                          TikTok first.)
--   usage_summary          this month's real counts, for "Usage this month".

create or replace function disconnect_connection(p_connection uuid)
returns void
language plpgsql security definer set search_path = public, private as $$
declare
  v_owner uuid;
begin
  select user_id into v_owner from platform_connections where id = p_connection;
  if v_owner is null then
    raise exception 'no such account';
  end if;
  if auth.uid() is not null and v_owner <> auth.uid() then
    raise exception 'that account is not yours';
  end if;

  delete from private.platform_credentials where connection_id = p_connection;
  update platform_connections
     set status = 'revoked', last_error = 'Disconnected by you'
   where id = p_connection;

  -- Nothing queued for it can go out any more.
  update publish_jobs set state = 'cancelled', last_error = 'account disconnected'
   where connection_id = p_connection and state = 'pending';
end $$;
revoke execute on function disconnect_connection(uuid) from anon, public;
grant execute on function disconnect_connection(uuid) to authenticated;

create or replace function usage_summary(p_brand uuid, p_from timestamptz)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'posted', (select count(*) from post_targets t join posts p on p.id = t.post_id
                where p.brand_id = p_brand and p.user_id = auth.uid()
                  and t.state = 'published' and t.published_at >= p_from),
    'sent_to_drafts', (select count(*) from post_targets t join posts p on p.id = t.post_id
                where p.brand_id = p_brand and p.user_id = auth.uid()
                  and t.state = 'sent_to_inbox'
                  and coalesce(t.published_at, t.scheduled_for, p.created_at) >= p_from),
    'scheduled', (select count(*) from publish_jobs j join post_targets t on t.id = j.post_target_id
                  join posts p on p.id = t.post_id
                where p.brand_id = p_brand and p.user_id = auth.uid() and j.state = 'pending'),
    'videos_made', (select count(*) from media_assets m
                where m.brand_id = p_brand and m.user_id = auth.uid() and m.created_at >= p_from),
    'plans_written', (select count(*) from content_plans c
                where c.brand_id = p_brand and c.user_id = auth.uid() and c.created_at >= p_from),
    'ai_generations', (select count(*) from generation_jobs g
                where g.brand_id = p_brand and g.user_id = auth.uid() and g.created_at >= p_from),
    'recorded_cost_cents', (select coalesce(sum(u.cost_cents), 0) from usage_events u
                where u.brand_id = p_brand and u.user_id = auth.uid() and u.created_at >= p_from),
    'by_kind', (select coalesce(jsonb_object_agg(kind, n), '{}'::jsonb) from (
                  select u.kind, sum(u.units) as n from usage_events u
                   where u.brand_id = p_brand and u.user_id = auth.uid() and u.created_at >= p_from
                   group by u.kind) k)
  );
$$;
revoke execute on function usage_summary(uuid, timestamptz) from anon, public;
grant execute on function usage_summary(uuid, timestamptz) to authenticated;
