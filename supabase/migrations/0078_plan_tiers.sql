-- The paid tiers, as the paywall shows them.
--
-- Netro, 29 Sep 2026: Pro, Max and one more, "so they choose and subscribe."
--
-- The paywall must never say a number the server does not enforce, and a number
-- typed into the app drifts the first time either side changes. So the app asks
-- here. Nothing in it is private -- it is what a plan gives, and it is on the
-- pricing screen for anyone to read -- so it is open to a signed-out visitor
-- too, which is what the onboarding paywall is.
create or replace function public.plan_tiers()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'code',      c.code,
        'name',      coalesce(c.display_name, c.code),
        'tier',      c.tier,
        'credits',   c.monthly_credits,
        'chat',      c.monthly_chat,
        'plan_days', c.max_plan_days,
        'accounts',  c.max_connections
      ) order by c.tier
    ),
    '[]'::jsonb)
    from plans_catalog c
   where c.code in ('creator', 'max', 'ultra');
$$;

revoke execute on function public.plan_tiers() from public;
grant  execute on function public.plan_tiers() to anon, authenticated;
