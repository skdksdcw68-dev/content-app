-- Remember which model this account is actually allowed to use.
--
-- Higgsfield's text-to-video catalogue is per-account: the same path answers
-- 404 `model_not_found` for one key and 200 for another, and their own error
-- table calls it "model not found *for this account*". So the app cannot know
-- from the outside which model a person can use -- it can only find out by
-- asking, and then it should stop asking.
--
-- Without this the fallback chain works but is wasteful in a specific way:
-- every job re-walks the list from the cheapest model down, spending a failed
-- round trip on each withdrawn one, every single day, forever. One column turns
-- that into one request.
--
-- Deliberately a hint and never a rule. `submit` still falls through the whole
-- list if the remembered model has since been withdrawn, because access is
-- granted and revoked on the provider's side and a stale memory here must not
-- become a permanent failure.

alter table private.provider_credentials
  add column if not exists last_good_model text;

comment on column private.provider_credentials.last_good_model is
  'Endpoint path of the last model that accepted a submission on this credential. A hint for ordering, never a restriction.';

-- Same contract as before, one column wider.
--
-- Dropped rather than replaced: `create or replace` cannot change the row type
-- defined by a function's OUT parameters (42P13), and adding a column to a
-- `returns table` is exactly that. Only the service role can execute this and
-- only the workers call it, so there is no window worth worrying about.
drop function if exists generator_for_user(uuid);

create or replace function generator_for_user(p_user uuid)
returns table (
  id              uuid,
  provider        text,
  secret_ct       text,
  last_probe_ok   boolean,
  last_good_model text
)
language sql
security definer
set search_path = public
as $$
  select c.id, c.provider, encode(c.secret_ct, 'hex'), c.last_probe_ok,
         c.last_good_model
    from private.provider_credentials c
   where c.user_id = p_user
     and c.revoked_at is null
     and octet_length(c.secret_ct) > 0
   order by c.last_probe_ok desc nulls last, c.created_at
   limit 1;
$$;

revoke execute on function generator_for_user(uuid) from anon, authenticated, public;

-- Written after a submission is accepted, and by nobody else.
--
-- Takes the credential id rather than the user so it cannot be used to go
-- looking for one, and writes a single column that carries no secret: the worst
-- a wrong value can do is cost one wasted request before the chain moves on.
create or replace function remember_good_model(
  p_credential_id uuid,
  p_model         text
) returns void
language sql
security definer
set search_path = public
as $$
  update private.provider_credentials
     set last_good_model = p_model
   where id = p_credential_id
     and coalesce(last_good_model, '') is distinct from p_model;
$$;

revoke execute on function remember_good_model(uuid, text) from anon, authenticated, public;
