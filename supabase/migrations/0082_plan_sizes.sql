-- How big each plan's month is, set by Netro on 19 Oct 2026: Pro $15, Max $45,
-- Ultra $125 of our cost (were $8, $24, $64 in 0079).
--
-- His rule: measure by what things really cost us, and keep a profit after
-- Apple's cut. The meter takes each chat, picture and video at its exact cost
-- (no markup since 19 Oct), so a plan's allowance IS the most it can cost us
-- in a month. After Apple's 15%, the worst month -- every % used, on the
-- cheapest billing -- still leaves:
--
--   Pro    monthly $25.49 - $15 = $10.49    yearly $17.71 - $15 = $2.71
--   Max    monthly $67.99 - $45 = $22.99    yearly $46.04 - $45 = $1.04
--   Ultra  monthly $169.99 - $125 = $44.99
--
-- The yearly plans are near break-even only for someone who uses everything
-- every month; told to him in those words before it was set. Proved by
-- scripts/rate-card-check.ts, which fails if any plan could lose money.

update public.plans_catalog set monthly_credits = 150000  where code = 'creator';
update public.plans_catalog set monthly_credits = 450000  where code = 'max';
update public.plans_catalog set monthly_credits = 1250000 where code = 'ultra';

-- The counters this month already opened carry the old limit until the next
-- spend refreshes it (`spend_credits` sets limit_value from the plan); lift
-- them now so the meter shows the new size at once.
update public.quota_counters q
   set limit_value = c.monthly_credits
  from plans_catalog c
 where q.kind = 'credit'
   and c.code = effective_plan(q.user_id)
   and q.period_start = (select u.period_start from usage_period(q.user_id) u);
