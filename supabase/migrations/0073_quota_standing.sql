-- How far can I go? Asked before the money, answered without spending any.
--
-- Abel, 26 Sep 2026: "why does the user is not allowed to see the costs and
-- the credits how far they can go?? plans also cost credits btw."
--
-- `consume_quota` has always known both numbers -- it is the thing that
-- refuses -- but the only way to hear from it was to try to spend. This reads
-- the same counters and the same plan the same way, changes nothing, and can
-- therefore be shown on a screen before somebody commits to a month of posts.
--
-- The gap it closes is the one the plan flow had: a 30-day plan quietly claims
-- thirty videos from the month's allowance, and nothing anywhere said so
-- until the thirty-first failed.
create or replace function quota_standing()
returns table (
  kind        text,
  used        integer,
  limit_value integer
)
language sql
security definer
set search_path = public
as $$
  with period as (select date_trunc('month', now())::date as start),
  plan as (
    select coalesce(
      (select plan_code from subscriptions
        where user_id = (select auth.uid()) and status in ('active','grace')),
      'free') as code
  ),
  limits as (
    select unnest(array['video_gen','image_gen']) as kind,
           unnest(array[c.monthly_video_gens, c.monthly_image_gens]) as limit_value
      from plans_catalog c
     where c.code = (select code from plan)
  )
  select l.kind,
         coalesce(q.used, 0) as used,
         l.limit_value
    from limits l
    left join quota_counters q
      on q.user_id = (select auth.uid())
     and q.period_start = (select start from period)
     and q.kind = l.kind;
$$;

revoke execute on function quota_standing() from anon, public;
grant  execute on function quota_standing() to authenticated;
