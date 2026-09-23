-- 0059: delete a plan, whatever state it is in.
--
-- Abel, 23 Sep 2026: "they can delete a plan." Until now only a proposal
-- could be discarded. Deleting a running plan keeps what already went out
-- (a posted video is a fact on TikTok; its row stays, unhooked from the
-- plan) and drops everything that was still to come, with its jobs.

create or replace function delete_plan(p_plan uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_plan content_plans;
begin
  select * into v_plan from content_plans where id = p_plan;
  if v_plan is null then
    raise exception 'no such plan' using errcode = 'P0002';
  end if;
  if v_plan.user_id <> (select auth.uid()) then
    raise exception 'that plan is not yours' using errcode = '42501';
  end if;

  -- What went out stays, as history without a plan.
  update posts set plan_id = null
   where plan_id = p_plan and status = 'posted';

  -- Everything else goes with the plan (posts cascade from content_plans;
  -- targets, jobs and assets cascade from posts).
  delete from content_plans where id = p_plan;
end $$;

revoke execute on function delete_plan(uuid) from anon, public;
grant  execute on function delete_plan(uuid) to authenticated;
