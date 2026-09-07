-- activate_plan declared `returns table (plan_id uuid, ...)`, and every OUT
-- column of a plpgsql function is also a variable in its body. So
--
--   update posts ... where plan_id = p_plan_id
--
-- had two candidates for `plan_id`: the OUT variable and posts.plan_id.
-- Postgres refuses to guess -- 42702, "column reference is ambiguous" -- and it
-- refuses at RUNTIME, not at create time, so the function deployed cleanly and
-- failed the first time a person pressed the button.
--
-- Renaming the OUT columns is the fix rather than qualifying the reference:
-- qualifying works until the next person adds a statement that forgets to.

drop function if exists activate_plan(uuid);

create or replace function activate_plan(p_plan_id uuid)
returns table (activated_plan uuid, posts_scheduled int)
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

  update posts p
     set status = 'scheduled',
         render_after = p.scheduled_for - make_interval(hours => coalesce(v_lead, 26))
   where p.plan_id = p_plan_id
     and p.status = 'planned'
     and p.scheduled_for is not null;
  get diagnostics v_count = row_count;

  return query select p_plan_id, v_count;
end $$;

revoke execute on function activate_plan(uuid) from anon, public;
grant execute on function activate_plan(uuid) to authenticated;
