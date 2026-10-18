-- One usage meter, counted in %, that every cost draws from.
--
-- Netro, 18 Oct 2026: "i want it to count with % like claude and chatgpt usage
-- costs coz we have both of the open ai and the fal ai costs, so uses fal or
-- uses open ai it counts from the 100." And: "make sure that the subscriptions
-- will never put us in shortage."
--
-- (This file replaces 0079_rate_card, which was written on 2 Oct and never
-- applied: its own rule was to wait for a phone build, and the meter replaced
-- it first. Nothing here assumes it ran.)
--
-- WHAT CHANGES
--
--   1. One unit is $0.0001 of what a thing costs at the rate card's price. Fine
--      enough that a chat reply (about $0.0009 of OpenAI) is counted, not
--      rounded away -- before this, chat, plans and captions were not counted
--      against anything but a message cap, so OpenAI was a cost no plan paid
--      for. The phone never shows a unit: it shows used / allowance as a %.
--      The ledger was a tenth of a cent (0077), so every number in it is
--      multiplied by ten, once.
--
--   2. A plan is a monthly budget of OUR cost, sized so the worst case still
--      earns (after Apple's 15%, and still after 30%):
--
--        plan          budget   pays us (15%)      worst month left over
--        Pro monthly     $8       $25.49             $17.49   ($12.99 at 30%)
--        Pro yearly      $8       $17.71 a month      $9.71   ($6.58 at 30%)
--        Max monthly    $24       $67.99             $43.99   ($31.99 at 30%)
--        Max yearly     $24       $46.04 a month     $22.04   ($13.92 at 30%)
--        Ultra monthly  $64      $169.99            $105.99   ($75.99 at 30%)
--
--      "Worst" is every % spent on models sold at cost. Most of the catalogue
--      carries a markup, so a real month costs less than the budget. Max is 3x
--      Pro and Ultra 8x, which is how the paywall says it.
--
--      Free is $0.05 -- about twenty chat replies, which is what it always had
--      -- and makes nothing (generation needs a paid plan, `chargeForGeneration`).
--
--   3. 🔴 THE MONTH NOW STARTS WHEN THEY PAID, not on the 1st. A subscriber who
--      bought on the 28th used to get a full allowance, then a second one three
--      days later -- two months of cost for one payment. That was the one way a
--      plan could cost more than it earned. Now the month runs from the
--      subscription's own period start (and, on a yearly plan, from the same
--      day each month after it). Free and the owner's override keep the
--      calendar month.
--
--   4. Chat and AI writes stop having caps of their own on the server: they
--      draw on the same meter, as Netro asked. The columns stay (an older app
--      build reads them).
--
-- Pre-launch: every counter is test data, so re-scaling it is safe. Run ONCE.

-- ------------------------------------------------------------ re-scale the books

update public.quota_counters
   set used        = used * 10,
       limit_value = limit_value * 10
 where kind = 'credit';

update public.credit_events
   set amount = amount * 10;

-- ------------------------------------------------------------------ the plans

update public.plans_catalog set monthly_credits = 500,    display_name = 'Free',            tier = 0 where code = 'free';
update public.plans_catalog set monthly_credits = 0,      display_name = 'Trial (retired)', tier = 0 where code = 'trial';
update public.plans_catalog set monthly_credits = 80000,  display_name = 'Pro',             tier = 1 where code = 'creator';
update public.plans_catalog set monthly_credits = 240000, display_name = 'Max',             tier = 2 where code = 'max';
update public.plans_catalog set monthly_credits = 640000, display_name = 'Ultra',           tier = 3 where code = 'ultra';

-- --------------------------------------------------------------- the month

-- Which month of usage this person is in: when it began (the key the counter
-- is kept under) and when it fills up again.
create or replace function public.usage_period(p_user uuid)
returns table (period_start date, resets_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_start  timestamptz;
  v_months int;
begin
  -- The owner's override is not a purchase and has no period of its own.
  if not exists (select 1 from plan_overrides o where o.user_id = p_user) then
    select s.current_period_start into v_start
      from subscriptions s
     where s.user_id = p_user
       and s.status in ('active', 'grace')
       and (s.current_period_end is null or s.current_period_end > now())
       and s.current_period_start is not null
       and s.current_period_start <= now();
  end if;

  if v_start is null then
    return query select date_trunc('month', now())::date,
                        date_trunc('month', now()) + interval '1 month';
    return;
  end if;

  -- Whole months since the period began: 0 on a monthly plan, 0 to 11 on a
  -- yearly one.
  v_months := (extract(year from age(now(), v_start)) * 12
             + extract(month from age(now(), v_start)))::int;
  return query select (v_start + make_interval(months => v_months))::date,
                      v_start + make_interval(months => v_months + 1);
end $$;

revoke execute on function public.usage_period(uuid) from anon, authenticated, public;

-- ---------------------------------------------------------------- spending

create or replace function public.spend_credits(
  p_user   uuid,
  p_amount int,
  p_ref    text,
  p_strict boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period date;
  v_resets timestamptz;
  v_plan   text := effective_plan(p_user);
  v_limit  int;
  v_used   int;
begin
  select u.period_start, u.resets_at into v_period, v_resets from usage_period(p_user) u;

  select monthly_credits into v_limit from plans_catalog where code = v_plan;
  if v_limit is null then
    return jsonb_build_object('ok', false, 'reason', 'no_plan', 'plan', v_plan, 'needed', p_amount,
                              'left', 0, 'limit', 0, 'resets_at', v_resets);
  end if;

  -- The limit follows the plan, so an upgrade mid-month lifts it at once.
  insert into quota_counters (user_id, period_start, kind, used, limit_value)
  values (p_user, v_period, 'credit', 0, v_limit)
  on conflict (user_id, period_start, kind) do update set limit_value = excluded.limit_value;

  if p_amount is null or p_amount <= 0 then
    select used into v_used from quota_counters
     where user_id = p_user and period_start = v_period and kind = 'credit';
    return jsonb_build_object('ok', coalesce(v_used, 0) < v_limit, 'spent', 0, 'plan', v_plan,
                              'left', greatest(v_limit - coalesce(v_used, 0), 0), 'limit', v_limit,
                              'resets_at', v_resets);
  end if;

  -- The same reference never charges twice: a retry finds its own spend.
  if exists (select 1 from credit_events where ref = p_ref and kind = 'spend') then
    select used into v_used from quota_counters
     where user_id = p_user and period_start = v_period and kind = 'credit';
    return jsonb_build_object('ok', true, 'spent', 0, 'repeat', true, 'plan', v_plan,
                              'left', greatest(v_limit - coalesce(v_used, 0), 0), 'limit', v_limit,
                              'resets_at', v_resets);
  end if;

  if p_strict then
    update quota_counters
       set used = used + p_amount
     where user_id = p_user and period_start = v_period and kind = 'credit'
       and used + p_amount <= limit_value
    returning used into v_used;

    if v_used is null then
      select used into v_used from quota_counters
       where user_id = p_user and period_start = v_period and kind = 'credit';
      return jsonb_build_object('ok', false, 'reason', 'not_enough', 'plan', v_plan, 'needed', p_amount,
                                'left', greatest(v_limit - coalesce(v_used, 0), 0), 'limit', v_limit,
                                'resets_at', v_resets);
    end if;
  else
    -- After the fact (a chat reply that has been written, a job that already
    -- ran): the provider has been paid either way, so take what is there
    -- rather than refuse, but never past the allowance.
    update quota_counters
       set used = least(limit_value, used + p_amount)
     where user_id = p_user and period_start = v_period and kind = 'credit'
    returning used into v_used;
  end if;

  insert into credit_events (user_id, kind, amount, ref, plan)
  values (p_user, 'spend', p_amount, p_ref, v_plan);

  return jsonb_build_object('ok', true, 'spent', p_amount, 'plan', v_plan,
                            'left', greatest(v_limit - v_used, 0), 'limit', v_limit,
                            'resets_at', v_resets);
end $$;

-- Gives usage back, once per reference, into the month the person is in now.
create or replace function public.give_back_credits(
  p_user   uuid,
  p_amount int,
  p_ref    text
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period date;
begin
  if p_amount is null or p_amount <= 0 then return 0; end if;
  select u.period_start into v_period from usage_period(p_user) u;

  begin
    insert into credit_events (user_id, kind, amount, ref) values (p_user, 'refund', p_amount, p_ref);
  exception when unique_violation then
    return 0;
  end;

  update quota_counters
     set used = greatest(0, used - p_amount)
   where user_id = p_user and period_start = v_period and kind = 'credit';
  return p_amount;
end $$;

revoke execute on function public.spend_credits(uuid, int, text, boolean) from anon, authenticated, public;
revoke execute on function public.give_back_credits(uuid, int, text)      from anon, authenticated, public;

-- ---------------------------------------------------------- what the phone sees

-- The meter. `percent_used` is what the app shows; `budget_usd` lets it say
-- what share of the month a price is before anything is made (a price arrives
-- in dollars of the rate card, and the share is price / budget).
create or replace function public.credits_standing()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with plan as (select effective_plan((select auth.uid())) as code),
  cat as (select c.* from plans_catalog c join plan on c.code = plan.code),
  period as (select * from usage_period((select auth.uid()))),
  used as (
    select coalesce(q.used, 0) as used
      from quota_counters q
     where q.user_id = (select auth.uid())
       and q.period_start = (select period_start from period)
       and q.kind = 'credit'
  ),
  n as (
    select coalesce((select monthly_credits from cat), 0) as allowance,
           least(coalesce((select used from used), 0), coalesce((select monthly_credits from cat), 0)) as used
  )
  select jsonb_build_object(
    'plan',         (select code from plan),
    'name',         (select display_name from cat),
    'tier',         coalesce((select tier from cat), 0),
    'allowance',    (select allowance from n),
    'used',         (select used from n),
    'left',         greatest((select allowance - used from n), 0),
    'percent_used', case when (select allowance from n) > 0
                         then round(100.0 * (select used from n) / (select allowance from n), 1) else 100 end,
    'budget_usd',   (select allowance from n) * 0.0001,
    'unit_usd',     0.0001,
    'resets_at',    (select resets_at from period)
  );
$$;

revoke execute on function public.credits_standing() from anon, public;
grant  execute on function public.credits_standing() to authenticated;

-- Same contract, with the usage month in place of the calendar one for credits.
create or replace function public.my_plan()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with plan as (select effective_plan(auth.uid()) as code),
  cat as (select c.* from plans_catalog c, plan where c.code = plan.code),
  period as (select * from usage_period(auth.uid())),
  used as (
    select kind, used from quota_counters
     where user_id = auth.uid() and period_start = date_trunc('month', now())::date),
  credit as (
    select used from quota_counters
     where user_id = auth.uid() and kind = 'credit'
       and period_start = (select period_start from period))
  select jsonb_build_object(
    'plan', (select code from plan),
    'name', (select display_name from cat),
    'tier', coalesce((select tier from cat), 0),
    'is_pro', coalesce((select tier from cat), 0) >= 1,
    'is_trial', (select code from plan) = 'trial',
    'product_id', (select product_id from subscriptions where user_id = auth.uid()),
    'expires_at', (select current_period_end from subscriptions where user_id = auth.uid()),
    'auto_renew', (select auto_renew from subscriptions where user_id = auth.uid()),
    'limits', (select jsonb_build_object(
                 'ai_writes', monthly_ai_writes, 'chat', monthly_chat,
                 'plan_days', max_plan_days, 'accounts', max_connections,
                 'credits', monthly_credits) from cat),
    'used', jsonb_build_object(
                 'ai_writes', coalesce((select used from used where kind = 'ai_write'), 0),
                 'chat', coalesce((select used from used where kind = 'chat'), 0),
                 'credits', coalesce((select used from credit), 0))
  );
$$;

create or replace function public.quota_standing()
returns table (
  kind        text,
  used        integer,
  limit_value integer
)
language sql
security definer
set search_path = public
as $$
  with plan as (select effective_plan((select auth.uid())) as code),
  period as (select * from usage_period((select auth.uid()))),
  limits as (
    select unnest(array['credit', 'video_gen', 'image_gen']) as kind,
           unnest(array[c.monthly_credits, c.monthly_video_gens, c.monthly_image_gens]) as limit_value
      from plans_catalog c
     where c.code = (select code from plan)
  )
  select l.kind,
         coalesce(q.used, 0) as used,
         l.limit_value
    from limits l
    left join quota_counters q
      on q.user_id = (select auth.uid())
     and q.period_start = case when l.kind = 'credit' then (select period_start from period)
                               else date_trunc('month', now())::date end
     and q.kind = l.kind;
$$;

revoke execute on function public.quota_standing() from anon, public;
grant  execute on function public.quota_standing() to authenticated;

-- The paid tiers for the paywall, with how much each gives next to Pro --
-- "3x the usage of Pro" -- which is how a meter in % is compared.
create or replace function public.plan_tiers()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with pro as (select nullif(monthly_credits, 0) as credits from plans_catalog where code = 'creator')
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'code',       c.code,
        'name',       coalesce(c.display_name, c.code),
        'tier',       c.tier,
        'credits',    c.monthly_credits,
        'usage',      round(c.monthly_credits::numeric / (select credits from pro), 1),
        'budget_usd', c.monthly_credits * 0.0001,
        'chat',       c.monthly_chat,
        'plan_days',  c.max_plan_days,
        'accounts',   c.max_connections
      ) order by c.tier
    ),
    '[]'::jsonb)
    from plans_catalog c
   where c.code in ('creator', 'max', 'ultra');
$$;

revoke execute on function public.plan_tiers() from public;
grant  execute on function public.plan_tiers() to anon, authenticated;
