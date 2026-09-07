-- Turning a plan into a schedule.
--
-- allocate_slots() has been able to lay out a month of timestamps since 0003,
-- and nothing has ever called it. This is the rest of that path: somewhere for
-- a proposed plan to live, and the one action that turns it into a schedule.
--
-- The split matters. `propose-plan` writes rows and changes nothing about the
-- world; activate_plan() is the moment a person says yes. Everything before it
-- is a document, and a document that turns out wrong costs a tap to discard.

-- --------------------------------------------------------- brand defaults

-- allocate_slots() joins brand_settings and raises if the row is missing, and
-- until now nothing created one -- the app inserts a brand and stops. Every
-- brand made before today therefore has no settings and no plan could be laid
-- out for it. Backfilled at the bottom.
--
-- security definer because `authenticated` is granted select and update on
-- brand_settings but deliberately not insert: the defaults are the server's to
-- choose, not the client's to claim.
create or replace function ensure_brand_defaults() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into brand_settings (brand_id, user_id)
  values (new.id, new.user_id)
  on conflict (brand_id) do nothing;
  return new;
end $$;

create trigger brands_default_settings
  after insert on brands
  for each row execute function ensure_brand_defaults();

insert into brand_settings (brand_id, user_id)
select b.id, b.user_id from brands b
on conflict (brand_id) do nothing;

-- ------------------------------------------------------------- activation

-- Says yes to a proposed plan.
--
-- security definer, so the ownership check is written out rather than left to
-- RLS -- the same reasoning as schedule_publish() in 0007. Without it, any
-- signed-in person could activate somebody else's plan by guessing an id.
--
-- One brand runs one plan (content_plans_one_active_idx), so whatever was
-- running is archived first. Archiving rather than deleting: the posts it
-- already published are attached to it and their history should not vanish
-- because a new month was planned.
create or replace function activate_plan(p_plan_id uuid)
returns table (plan_id uuid, scheduled int)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan  content_plans;
  v_lead  smallint;
  v_count int;
begin
  select * into v_plan from content_plans where id = p_plan_id;

  if v_plan is null then
    raise exception 'no such plan';
  end if;

  if auth.uid() is not null and v_plan.user_id <> auth.uid() then
    raise exception 'that plan is not yours';
  end if;

  if v_plan.status not in ('draft', 'proposed', 'paused') then
    raise exception 'that plan is already %', v_plan.status;
  end if;

  select render_lead_hours into v_lead
    from brand_settings where brand_id = v_plan.brand_id;

  update content_plans
     set status = 'archived'
   where brand_id = v_plan.brand_id
     and id <> p_plan_id
     and status in ('active', 'paused');

  update content_plans
     set status = 'active', approved_at = now(), approved_by = v_plan.user_id
   where id = p_plan_id;

  -- render_after is when the media has to start being made, not when the post
  -- goes out. Set here rather than at insert because it depends on a setting
  -- the person may have changed between proposing and approving.
  update posts
     set status = 'scheduled',
         render_after = scheduled_for - make_interval(hours => coalesce(v_lead, 26))
   where plan_id = p_plan_id
     and status = 'planned'
     and scheduled_for is not null;
  get diagnostics v_count = row_count;

  return query select p_plan_id, v_count;
end $$;

-- Throws a proposal away. Not a delete: a plan you rejected is evidence about
-- what the agent gets wrong, and brand_memory is meant to learn from it.
create or replace function discard_plan(p_plan_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_plan content_plans;
begin
  select * into v_plan from content_plans where id = p_plan_id;

  if v_plan is null then
    raise exception 'no such plan';
  end if;

  if auth.uid() is not null and v_plan.user_id <> auth.uid() then
    raise exception 'that plan is not yours';
  end if;

  update content_plans set status = 'archived' where id = p_plan_id;
  delete from posts where plan_id = p_plan_id and status = 'planned';
end $$;

revoke execute on function activate_plan(uuid) from anon, public;
revoke execute on function discard_plan(uuid)  from anon, public;
grant execute on function activate_plan(uuid) to authenticated;
grant execute on function discard_plan(uuid)  to authenticated;
