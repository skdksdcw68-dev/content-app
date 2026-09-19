-- 0051: Autocast Pro.
--
-- Who is Pro is decided here, from rows only the server writes after it has
-- verified Apple's signature (verify-purchase, apple-notifications-v2). The
-- phone reads the answer through my_plan(); it never writes it.
--
-- Plans:
--   free     7-day plans, 1 account, 5 AI writes and 20 chat messages a month
--   trial    the 3-day yearly trial: a taste, capped -- 7-day plans, 10 AI
--            writes, 50 chat messages. A trial costs us about $0.16 at most.
--   creator  Pro. 30-day plans, fair-use caps sized so a heavy month stays
--            around $2 of AI (see memory: launch-plan).
--
-- AI video stays bring-your-own: monthly_video_gens is not what gates it.

alter table subscriptions add column if not exists product_id text;
alter table subscriptions add column if not exists is_trial boolean not null default false;
alter table subscriptions add column if not exists environment text;
alter table subscriptions add column if not exists auto_renew boolean;

alter table plans_catalog add column if not exists monthly_ai_writes int not null default 0;
alter table plans_catalog add column if not exists monthly_chat int not null default 0;

insert into plans_catalog (code, monthly_image_gens, monthly_video_gens, monthly_llm_cents, max_brands, max_connections, max_plan_days)
values ('trial', 30, 0, 200, 1, 1, 7)
on conflict (code) do nothing;

update plans_catalog set monthly_ai_writes = 5,   monthly_chat = 20,   max_plan_days = 7  where code = 'free';
update plans_catalog set monthly_ai_writes = 10,  monthly_chat = 50,   max_plan_days = 7  where code = 'trial';
update plans_catalog set monthly_ai_writes = 500, monthly_chat = 1000, max_plan_days = 30 where code = 'creator';

-- The one place that turns a subscription row into a plan.
create or replace function effective_plan(p_user uuid)
returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select case when s.is_trial then 'trial' else s.plan_code end
       from subscriptions s
      where s.user_id = p_user
        and s.status in ('active', 'grace')
        and (s.current_period_end is null or s.current_period_end > now())),
    'free');
$$;
revoke execute on function effective_plan(uuid) from anon, public;

-- Same contract as before (0003), with the new kinds and the effective plan.
create or replace function consume_quota(p_user uuid, p_kind text, p_units int)
returns boolean
language plpgsql set search_path = public as $$
declare
  v_period date := date_trunc('month', now())::date;
  v_limit  int;
  v_ok     boolean;
begin
  select case p_kind
           when 'image_gen' then c.monthly_image_gens
           when 'video_gen' then c.monthly_video_gens
           when 'llm_cents' then c.monthly_llm_cents
           when 'ai_write'  then c.monthly_ai_writes
           when 'chat'      then c.monthly_chat
           else 0
         end
    into v_limit
    from plans_catalog c
   where c.code = effective_plan(p_user);

  if v_limit is null then return false; end if;

  insert into quota_counters (user_id, period_start, kind, used, limit_value)
  values (p_user, v_period, p_kind, 0, v_limit)
  on conflict (user_id, period_start, kind) do update set limit_value = excluded.limit_value;

  update quota_counters
     set used = used + p_units
   where user_id = p_user and period_start = v_period and kind = p_kind
     and used + p_units <= limit_value
  returning true into v_ok;

  return coalesce(v_ok, false);
end $$;
revoke execute on function consume_quota(uuid, text, int) from anon, authenticated, public;

-- What the phone shows: the plan, whether it is a trial, when it ends, and
-- this month's use against each cap.
create or replace function my_plan()
returns jsonb
language sql stable security definer set search_path = public as $$
  with plan as (select effective_plan(auth.uid()) as code),
  cat as (select c.* from plans_catalog c, plan where c.code = plan.code),
  used as (
    select kind, used from quota_counters
     where user_id = auth.uid() and period_start = date_trunc('month', now())::date)
  select jsonb_build_object(
    'plan', (select code from plan),
    'is_pro', (select code from plan) in ('creator', 'studio', 'trial'),
    'is_trial', (select code from plan) = 'trial',
    'product_id', (select product_id from subscriptions where user_id = auth.uid()),
    'expires_at', (select current_period_end from subscriptions where user_id = auth.uid()),
    'auto_renew', (select auto_renew from subscriptions where user_id = auth.uid()),
    'limits', (select jsonb_build_object(
                 'ai_writes', monthly_ai_writes, 'chat', monthly_chat,
                 'plan_days', max_plan_days, 'accounts', max_connections) from cat),
    'used', jsonb_build_object(
                 'ai_writes', coalesce((select used from used where kind = 'ai_write'), 0),
                 'chat', coalesce((select used from used where kind = 'chat'), 0))
  );
$$;
revoke execute on function my_plan() from anon, public;
grant execute on function my_plan() to authenticated;
