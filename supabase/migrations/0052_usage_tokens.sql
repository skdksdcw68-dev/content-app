-- 0052: measure AI cost instead of estimating it.
--
-- Until now usage_events counted units with cost_cents rounded to whole cents
-- -- a caption costs 0.04 of a cent, so every row said 0 -- and agent_runs'
-- token columns were never filled. Each AI call now records its model, its
-- real token counts and its cost in dollars at full precision.

alter table usage_events add column if not exists model text;
alter table usage_events add column if not exists input_tokens int;
alter table usage_events add column if not exists output_tokens int;
alter table usage_events add column if not exists cost_usd numeric(12, 6);

-- The monthly picture across everyone, for deciding prices with real numbers.
create or replace function ai_cost_summary(p_from timestamptz default date_trunc('month', now()))
returns table (kind text, model text, calls bigint, input_tokens bigint, output_tokens bigint,
               cost_usd numeric, users bigint, cost_per_call_usd numeric)
language sql stable security definer set search_path = public as $$
  select kind, model, count(*), sum(input_tokens), sum(output_tokens),
         round(sum(cost_usd), 4), count(distinct user_id),
         round(sum(cost_usd) / nullif(count(*), 0), 6)
    from usage_events
   where created_at >= p_from and cost_usd is not null
   group by kind, model
   order by 6 desc nulls last;
$$;
revoke execute on function ai_cost_summary(timestamptz) from anon, authenticated, public;
