-- The render queue for story videos, recovered from production.
--
-- Built between 19 and 21 Oct 2026 and applied by hand, so it never reached
-- the repository -- the disk it was written on failed before the push. On
-- 31 Oct 2026 the live definitions were read back out of the database
-- (information_schema, pg_get_constraintdef, pg_indexes, pg_policies,
-- pg_get_functiondef) and written here exactly as they run.
--
-- A story job (agent_runs, kind 'story') asks for ONE render here; the render
-- service (abelabel16/netro-render) claims it with a lease, renders, and
-- finishes it. The partial unique index is what makes a retried step return
-- the first render instead of paying for a second.
--
-- Already applied on dosszkllkassvyprkhrg; every statement is safe to re-run.

create table if not exists public.render_jobs (
  id          uuid primary key default gen_random_uuid(),
  run_id      uuid not null references public.agent_runs(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  status      text not null default 'queued'
              check (status in ('queued', 'rendering', 'done', 'failed', 'cancelled')),
  spec        jsonb not null,
  attempts    smallint not null default 0,
  claimed_by  text,
  lease_until timestamptz,
  output_path text,
  qc          jsonb,
  error       text,
  created_at  timestamptz not null default now(),
  finished_at timestamptz
);

create index if not exists render_jobs_due on public.render_jobs (status, lease_until);
create unique index if not exists render_jobs_one_live_per_run on public.render_jobs (run_id)
  where status in ('queued', 'rendering', 'done');

alter table public.render_jobs enable row level security;
drop policy if exists render_jobs_read on public.render_jobs;
create policy render_jobs_read on public.render_jobs for select to authenticated
  using ((select auth.uid()) = user_id);

CREATE OR REPLACE FUNCTION public.claim_render_job(p_worker text, p_lease integer DEFAULT 600)
 RETURNS SETOF render_jobs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  select id into v_id
    from render_jobs
   where (status = 'queued' or (status = 'rendering' and lease_until < now()))
     and attempts < 3
   order by created_at
   limit 1
   for update skip locked;
  if v_id is null then return; end if;

  return query
    update render_jobs
       set status = 'rendering', claimed_by = p_worker,
           lease_until = now() + make_interval(secs => p_lease),
           attempts = attempts + 1
     where id = v_id
    returning *;
end $function$;

revoke execute on function public.claim_render_job(text, integer) from public, anon, authenticated;
grant execute on function public.claim_render_job(text, integer) to service_role;

CREATE OR REPLACE FUNCTION public.finish_render_job(p_job uuid, p_ok boolean, p_path text, p_qc jsonb, p_error text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update render_jobs
     set status = case when p_ok then 'done' else 'failed' end,
         output_path = p_path, qc = p_qc, error = p_error,
         lease_until = null, finished_at = now()
   where id = p_job;
$function$;

revoke execute on function public.finish_render_job(uuid, boolean, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.finish_render_job(uuid, boolean, text, jsonb, text) to service_role;
