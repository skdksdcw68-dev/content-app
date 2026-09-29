-- Credits, and three tiers to spend them in.
--
-- Netro, 29 Sep 2026: "we do need to provide a pricing things as well, like we
-- can split it, pro, max and 1 more so they choose and subscribe."
--
-- 🔴 THE HOLE THIS CLOSES. A picture or a video made in chat was never counted.
-- `consume_quota` guarded scheduled posts and chat MESSAGES, and the `generate`
-- action -- how nearly everything is made now -- called neither. A free
-- account made an image on the house generator with no limit at all (tested
-- 29 Sep), and a Pro account could have made a thousand Veo videos. Counting
-- things was never going to be right anyway: a Wan clip costs us $0.25 and a
-- Veo one with sound $3.20, and both were "one video".
--
-- So generation is paid for in CREDITS. One credit is a tenth of a cent of what
-- the provider charges us (the same number the generator bar has been showing
-- beside the send button since 26 Sep). A plan is a monthly allowance of them.
--
--   free    100      cheap pictures only
--   trial   1,500    the three-day trial on the yearly plan
--   Pro     8,000    creator   $29.99 a month
--   Max     26,000   max       $79.99 a month
--   Ultra   70,000   ultra     $199.99 a month
--
-- Spent BEFORE the job starts and only when it runs on our money (the house
-- generator), returned if the job fails, settled to the provider's own charge
-- if it succeeds. Fails CLOSED: a counter that cannot be read stops the job,
-- because an uncounted call is our bill.

-- ------------------------------------------------------------------ the plans

alter table public.plans_catalog add column if not exists monthly_credits int not null default 0;
alter table public.plans_catalog add column if not exists display_name   text;
alter table public.plans_catalog add column if not exists tier           int  not null default 0;

insert into public.plans_catalog
  (code, max_brands, max_connections, max_plan_days, monthly_ai_writes, monthly_chat,
   monthly_image_gens, monthly_llm_cents, monthly_video_gens, monthly_credits, display_name, tier)
values
  ('max',    5, 10, 60, 1500,  3000,  900,  5000, 180, 26000, 'Max',   2),
  ('ultra', 10, 20, 90, 5000, 10000, 3000, 12000, 500, 70000, 'Ultra', 3)
on conflict (code) do update set
  max_brands         = excluded.max_brands,
  max_connections    = excluded.max_connections,
  max_plan_days      = excluded.max_plan_days,
  monthly_ai_writes  = excluded.monthly_ai_writes,
  monthly_chat       = excluded.monthly_chat,
  monthly_image_gens = excluded.monthly_image_gens,
  monthly_llm_cents  = excluded.monthly_llm_cents,
  monthly_video_gens = excluded.monthly_video_gens,
  monthly_credits    = excluded.monthly_credits,
  display_name       = excluded.display_name,
  tier               = excluded.tier;

update public.plans_catalog set monthly_credits = 100,  display_name = 'Free',   tier = 0 where code = 'free';
update public.plans_catalog set monthly_credits = 1500, display_name = 'Trial',  tier = 1 where code = 'trial';
update public.plans_catalog set monthly_credits = 8000, display_name = 'Pro',    tier = 1 where code = 'creator';
-- The old "studio" row was never sold and has no chat allowance. Left in place
-- so nothing that names it breaks, and given nothing to spend.
update public.plans_catalog set monthly_credits = 0, display_name = 'Studio (retired)', tier = 0 where code = 'studio';

-- The owner's own accounts run on the top plan, so testing the app does not
-- spend down a customer-sized allowance -- and without touching their
-- subscription rows, which are Apple's sandbox purchases and are how the
-- paywall is tested. `effective_plan` is the one place a plan is decided, so
-- an override is one line there.
create table if not exists public.plan_overrides (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  plan_code  text not null references public.plans_catalog(code),
  note       text,
  created_at timestamptz not null default now()
);
alter table public.plan_overrides enable row level security;

insert into public.plan_overrides (user_id, plan_code, note)
select id, 'ultra', 'owner'
  from auth.users
 where email in ('abelamare1633@gmail.com', 'abelamere45@icloud.com')
on conflict (user_id) do nothing;

create or replace function public.effective_plan(p_user uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select o.plan_code from plan_overrides o where o.user_id = p_user),
    (select case when s.is_trial then 'trial' else s.plan_code end
       from subscriptions s
      where s.user_id = p_user
        and s.status in ('active', 'grace')
        and (s.current_period_end is null or s.current_period_end > now())),
    'free');
$$;

-- ------------------------------------------------------------------- the books

-- Every credit that moved, and why. One spend and one refund per reference at
-- most (the unique index), which is what makes a retried request and a
-- twice-failed job safe: neither can charge or refund twice.
create table if not exists public.credit_events (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('spend', 'refund')),
  amount     int  not null check (amount > 0),
  ref        text not null,
  plan       text,
  created_at timestamptz not null default now()
);
create unique index if not exists credit_events_one_per_ref on public.credit_events (ref, kind);
create index if not exists credit_events_by_user on public.credit_events (user_id, created_at desc);

-- Nothing reads or writes this through the API. The functions below are the
-- only door, and they are not reachable by a signed-in person.
alter table public.credit_events enable row level security;

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
  v_period date := date_trunc('month', now())::date;
  v_plan   text := effective_plan(p_user);
  v_limit  int;
  v_used   int;
begin
  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('ok', true, 'spent', 0, 'plan', v_plan);
  end if;

  select monthly_credits into v_limit from plans_catalog where code = v_plan;
  if v_limit is null then
    return jsonb_build_object('ok', false, 'reason', 'no_plan', 'plan', v_plan, 'needed', p_amount, 'left', 0, 'limit', 0);
  end if;

  -- The same reference never charges twice: a retry finds its own spend.
  if exists (select 1 from credit_events where ref = p_ref and kind = 'spend') then
    select used into v_used from quota_counters
     where user_id = p_user and period_start = v_period and kind = 'credit';
    return jsonb_build_object('ok', true, 'spent', 0, 'repeat', true, 'plan', v_plan,
                              'left', greatest(v_limit - coalesce(v_used, 0), 0), 'limit', v_limit);
  end if;

  -- The limit follows the plan, so an upgrade mid-month lifts it at once.
  insert into quota_counters (user_id, period_start, kind, used, limit_value)
  values (p_user, v_period, 'credit', 0, v_limit)
  on conflict (user_id, period_start, kind) do update set limit_value = excluded.limit_value;

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
                                'left', greatest(v_limit - coalesce(v_used, 0), 0), 'limit', v_limit);
    end if;
  else
    -- Settling a job that already ran: take what is there rather than refuse,
    -- because the provider has been paid either way, but never past the
    -- allowance.
    update quota_counters
       set used = least(limit_value, used + p_amount)
     where user_id = p_user and period_start = v_period and kind = 'credit'
    returning used into v_used;
  end if;

  insert into credit_events (user_id, kind, amount, ref, plan)
  values (p_user, 'spend', p_amount, p_ref, v_plan);

  return jsonb_build_object('ok', true, 'spent', p_amount, 'plan', v_plan,
                            'left', greatest(v_limit - v_used, 0), 'limit', v_limit);
end $$;

-- Gives credits back, once per reference.
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
  v_period date := date_trunc('month', now())::date;
begin
  if p_amount is null or p_amount <= 0 then return 0; end if;

  begin
    insert into credit_events (user_id, kind, amount, ref) values (p_user, 'refund', p_amount, p_ref);
  exception when unique_violation then
    return 0;
  end;

  -- Into this month's counter, whichever month the spend was in: a job that
  -- fails across midnight on the 31st still gives the person their credits.
  update quota_counters
     set used = greatest(0, used - p_amount)
   where user_id = p_user and period_start = v_period and kind = 'credit';
  return p_amount;
end $$;

-- Gives back everything a reference spent. What a failed job calls.
create or replace function public.refund_spend(p_user uuid, p_ref text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount int;
begin
  select amount into v_amount from credit_events
   where ref = p_ref and kind = 'spend' and user_id = p_user;
  if v_amount is null then return 0; end if;
  return give_back_credits(p_user, v_amount, p_ref);
end $$;

revoke execute on function public.spend_credits(uuid, int, text, boolean) from anon, authenticated, public;
revoke execute on function public.give_back_credits(uuid, int, text)      from anon, authenticated, public;
revoke execute on function public.refund_spend(uuid, text)                from anon, authenticated, public;

-- ------------------------------------------------- a failed job gives them back

-- On the table rather than in `finish_agent_run`, because runs also die where
-- no function of ours is watching: `reap_leases` marks a run failed directly
-- after three lost workers. A trigger sees every road.
create or replace function public.refund_failed_run_credits()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status::text in ('failed', 'cancelled')
     and old.status is distinct from new.status
     and new.input ? 'credit_ref' then
    perform refund_spend(new.user_id, new.input->>'credit_ref');
  end if;
  return new;
end $$;

drop trigger if exists agent_runs_refund_credits on public.agent_runs;
create trigger agent_runs_refund_credits
  after update of status on public.agent_runs
  for each row execute function public.refund_failed_run_credits();

-- The scheduler's own jobs (a series posting one video a day) carry the same
-- reference in a column, because their `input` is rewritten when the job is
-- submitted.
alter table public.generation_jobs add column if not exists credit_ref text;

create or replace function public.refund_failed_job_credits()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status::text in ('failed', 'cancelled', 'rejected_nsfw')
     and old.status is distinct from new.status
     and new.credit_ref is not null then
    perform refund_spend(new.user_id, new.credit_ref);
  end if;
  return new;
end $$;

drop trigger if exists generation_jobs_refund_credits on public.generation_jobs;
create trigger generation_jobs_refund_credits
  after update of status on public.generation_jobs
  for each row execute function public.refund_failed_job_credits();

-- ---------------------------------------------------------- what the phone sees

create or replace function public.credits_standing()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with plan as (select effective_plan((select auth.uid())) as code),
  cat as (select c.* from plans_catalog c join plan on c.code = plan.code),
  used as (
    select coalesce(q.used, 0) as used
      from quota_counters q
     where q.user_id = (select auth.uid())
       and q.period_start = date_trunc('month', now())::date
       and q.kind = 'credit'
  )
  select jsonb_build_object(
    'plan',      (select code from plan),
    'name',      (select display_name from cat),
    'tier',      coalesce((select tier from cat), 0),
    'allowance', coalesce((select monthly_credits from cat), 0),
    'used',      coalesce((select used from used), 0),
    'left',      greatest(coalesce((select monthly_credits from cat), 0) - coalesce((select used from used), 0), 0),
    'resets_at', (date_trunc('month', now()) + interval '1 month')
  );
$$;

revoke execute on function public.credits_standing() from anon, public;
grant  execute on function public.credits_standing() to authenticated;

-- Same contract as before, with the plan's name and tier and its credits.
-- `is_pro` is now "a paid tier", not a list of plan names -- there are three.
create or replace function public.my_plan()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with plan as (select effective_plan(auth.uid()) as code),
  cat as (select c.* from plans_catalog c, plan where c.code = plan.code),
  used as (
    select kind, used from quota_counters
     where user_id = auth.uid() and period_start = date_trunc('month', now())::date)
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
                 'credits', coalesce((select used from used where kind = 'credit'), 0))
  );
$$;

-- "This month", as the sheets read it: the credits first, then the old counts
-- (which stop moving once generation is paid for in credits, and are kept only
-- so an older build of the app still draws something).
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
  with period as (select date_trunc('month', now())::date as start),
  plan as (select effective_plan((select auth.uid())) as code),
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
     and q.period_start = (select start from period)
     and q.kind = l.kind;
$$;

revoke execute on function public.quota_standing() from anon, public;
grant  execute on function public.quota_standing() to authenticated;
