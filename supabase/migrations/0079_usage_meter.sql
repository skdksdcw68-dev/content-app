-- Ordinary credits, a rate card, and nothing free.
--
-- Netro, 2 Oct 2026, three decisions in one afternoon:
--
--   1. "Instead of showing the user a money credit, it is better to show them a
--      normal credit, as Higgsfield does." A credit used to be a tenth of a cent
--      of what the provider charged us, so a Kling clip read 350 and every model
--      earned the same margin. It is now a cent of the rate card's base price,
--      and each model carries its own markup (fal.ts `billable`): a Kling clip
--      is 35, Veo 3.1 with sound 480. The ledger is therefore ten times smaller,
--      and this migration re-scales every number that was already in it.
--
--   2. Prices approved: Pro $29.99 / $249.99, Max $79.99 / $649.99, Ultra
--      $199.99 a month only (Apple's US ladder stops near $1,000, and Ultra
--      yearly at $999.99 earns about 1% at full use).
--
--   3. "There is no free trial for any new users. They only get paid things."
--      So the Free plan gets no credits, and the retired trial plan none either.
--      (The 3-day trial offer itself lives in App Store Connect and is removed
--      by scripts/remove-trials.ts; this is the server's half, so that even a
--      trial entitlement that slipped through would make nothing.)
--
-- And one hole closed while the numbers are open. Chat on the dearer model costs
-- about $0.0075 a message, and Max allowed 3,000 and Ultra 10,000 of them: a
-- Max yearly subscriber using all of both would have cost more than they paid
-- (-$2.46 a month). Max 2,000 and Ultra 4,000 turn that into +$5 and +$70, and
-- nobody normal sends 67 chat messages a day.
--
-- Pre-launch there is no paying customer, so every counter is test data and
-- scaling it is safe. Run ONCE: dividing twice would shrink the books again.

-- ------------------------------------------------------------ re-scale the books

update public.quota_counters
   set used        = ceil(used / 10.0)::int,
       limit_value = ceil(limit_value / 10.0)::int
 where kind = 'credit';

-- A refund looks its amount up here, so a job in flight across this change
-- hands back the same number it was charged.
update public.credit_events
   set amount = greatest(1, ceil(amount / 10.0)::int);

-- ------------------------------------------------------------------ the plans

update public.plans_catalog set monthly_credits = 0,    display_name = 'Free',              tier = 0 where code = 'free';
update public.plans_catalog set monthly_credits = 0,    display_name = 'Trial (retired)',   tier = 0 where code = 'trial';
update public.plans_catalog set monthly_credits = 800,  display_name = 'Pro',               tier = 1 where code = 'creator';
update public.plans_catalog set monthly_credits = 2600, display_name = 'Max',               tier = 2, monthly_chat = 2000 where code = 'max';
update public.plans_catalog set monthly_credits = 7000, display_name = 'Ultra',             tier = 3, monthly_chat = 4000 where code = 'ultra';
