-- Where this month's usage went, for the Usage screen.
--
-- Netro, 19 Oct 2026: "The user must click Usage to see how their usage is
-- running." The meter (0079) says how much is gone; this says on what --
-- chat, analytics, research, plans, writing, pictures, videos -- each as a
-- share of the month, from the same ledger the meter is spent from.
--
-- Every spend's reference names what it paid for: "ai:<kind>:<id>" for an AI
-- call (usage.ts), "gen:<capability>:<id>" for a generation (credits.ts, from
-- 19 Oct). A refund or a settlement carries its spend's reference, so it nets
-- out of the same group. Older spends with a bare id count as "other".
create or replace function public.usage_breakdown()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with me as (select (select auth.uid()) as id),
  period as (select * from usage_period((select id from me))),
  cat as (
    select c.monthly_credits as allowance
      from plans_catalog c
     where c.code = effective_plan((select id from me))
  ),
  moved as (
    select case
             when e.ref like 'gen:video%'                        then 'videos'
             when e.ref like 'gen:image%'                        then 'pictures'
             when e.ref like 'gen:audio%' or e.ref like 'gen:voice%' then 'audio'
             when e.ref like 'ai:chat_%'                         then 'chat'
             when e.ref like 'ai:insight%'                       then 'analytics'
             when e.ref like 'ai:research%'                      then 'research'
             when e.ref like 'ai:campaign%' or e.ref like 'ai:plan_%' then 'plans'
             when e.ref like 'ai:caption%' or e.ref like 'ai:video_understand%'
               or e.ref like 'ai:inspiration%'                   then 'writing'
             else 'other'
           end as kind,
           case when e.kind = 'spend' then e.amount else -e.amount end as units
      from credit_events e
     where e.user_id = (select id from me)
       and e.created_at >= (select resets_at from period) - interval '1 month'
  ),
  groups as (
    select kind, greatest(sum(units), 0)::bigint as units
      from moved
     group by kind
    having sum(units) > 0
  )
  select jsonb_build_object(
    'allowance', coalesce((select allowance from cat), 0),
    'resets_at', (select resets_at from period),
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', g.kind,
               'units', g.units,
               'percent', case when coalesce((select allowance from cat), 0) > 0
                               then round(100.0 * g.units / (select allowance from cat), 2) else 0 end
             ) order by g.units desc)
        from groups g), '[]'::jsonb)
  );
$$;

revoke execute on function public.usage_breakdown() from anon, public;
grant  execute on function public.usage_breakdown() to authenticated;
