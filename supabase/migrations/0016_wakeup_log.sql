-- What the wake-up calls actually got back.
--
-- last_fired_at proves tick_generations() RAN. It does not prove the HTTP call
-- landed, and that gap is precisely how 0007 failed invisibly for four minutes
-- while every surface said healthy. pg_net records every response in
-- net._http_response; this is a read-only window onto the last few.
--
-- Truncated to 200 characters because the body is ours -- {"claimed":0} and
-- friends -- and a full body would be a way to read whatever an endpoint
-- happened to return.
create or replace function recent_wakeups(p_limit int default 10)
returns table (
  id          bigint,
  status_code integer,
  body        text,
  created     timestamptz,
  timed_out   boolean,
  error_msg   text
)
language sql
security definer
set search_path = public, net
as $$
  select r.id, r.status_code, left(coalesce(r.content, ''), 200),
         r.created, r.timed_out, r.error_msg
    from net._http_response r
   order by r.id desc
   limit p_limit;
$$;

revoke execute on function recent_wakeups(int) from anon, authenticated, public;
