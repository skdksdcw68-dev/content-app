-- A scheduled drop is made ahead but is a surprise until its time (0095): the
-- Library leaves out what a job made for a delivery that has not happened yet.
create or replace function public.my_library(p_kind text default null, p_limit integer default 120)
returns table(id uuid, kind text, title text, status text, version integer, parent_id uuid, storage_path text,
              mime text, byte_size bigint, body jsonb, provider text, model text, estimated_cost jsonb,
              actual_cost jsonb, created_at timestamptz)
language sql
security definer
set search_path to 'public'
as $function$
  select a.id, a.kind, a.title, a.status, a.version, a.parent_id,
         a.storage_path, a.mime, a.byte_size, a.body,
         a.provider, a.model, a.estimated_cost, a.actual_cost, a.created_at
    from artifacts a
   where a.user_id = (select auth.uid())
     and a.kind in ('image', 'video', 'audio')
     and a.status = 'ready'
     and a.storage_path is not null
     and (p_kind is null or a.kind = p_kind)
     and not exists (
       select 1 from agent_runs r
        where r.id = a.run_id
          and r.input ? 'deliver_at'
          and (r.input->>'deliver_at')::timestamptz > now()
     )
   order by a.created_at desc
   limit greatest(1, least(p_limit, 300));
$function$;
