-- Whether Autocast's own generator can make this right now, for the phone.
--
-- Found 18 Oct 2026: the app decided "is there a generator?" from the
-- person's OWN connections (`my_connections`, `my_generators`). The house
-- generator (0068) belongs to a system account, so for every customer that
-- answer was no -- Autopilot's "Make videos with AI", the series flow and the
-- Create screen all asked them to "connect a video generator", which nobody
-- needs to do since Autocast brings the models.
--
-- Says nothing private: only whether an active house connection has an
-- available model of that kind. Whether THIS person may use it (a paid plan)
-- is still decided where the money is spent, `chargeForGeneration`.
create or replace function public.house_can_make(p_capability text default 'video_generation')
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from connection_models m
      join connections c on c.id = m.connection_id
     where c.is_house
       and c.status = 'active'
       and c.revoked_at is null
       and m.capability = p_capability
       and m.available
  );
$$;

revoke execute on function public.house_can_make(text) from public, anon;
grant  execute on function public.house_can_make(text) to authenticated;
