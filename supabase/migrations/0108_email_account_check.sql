-- Pre-auth account lookup for app/(onboarding)/email.tsx, replacing the
-- paginate-the-whole-admin-user-list approach the check-email edge function
-- shipped with earlier today. That worked but walked every user page over
-- HTTP on each call; this is a single indexed query on auth.users.email.
--
-- Returns three things the sign-up/sign-in screens each need:
--   exists       - is this email registered at all
--   has_password - can signInWithPassword ever succeed for it? A Google-only
--                  or Apple-only signup has NO password, so telling that user
--                  "incorrect password" sends them into a loop they cannot
--                  win; they need Forgot password (which sets one) or their
--                  social button instead.
--   providers    - which sign-in methods this account actually has, so the
--                  UI can say "this email uses Google" rather than guessing.
--
-- security definer because auth.users/auth.identities are not readable by
-- the anon or authenticated roles, and must not become so. EXECUTE is
-- granted ONLY to service_role: the client never calls this directly, the
-- check-email edge function does (with the service key) and applies its own
-- rate limiting first. Granting this to anon would hand every app binary a
-- free, unthrottled account-enumeration oracle.
create or replace function public.email_account_status(check_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_has_password boolean;
  v_providers text[];
begin
  select u.id, (u.encrypted_password is not null and u.encrypted_password <> '')
    into v_user_id, v_has_password
  from auth.users u
  where lower(u.email) = lower(trim(check_email))
    and u.deleted_at is null
    and u.is_anonymous = false
  limit 1;

  if v_user_id is null then
    return jsonb_build_object('exists', false, 'has_password', false, 'providers', '[]'::jsonb);
  end if;

  select coalesce(array_agg(distinct i.provider), '{}')
    into v_providers
  from auth.identities i
  where i.user_id = v_user_id;

  return jsonb_build_object(
    'exists', true,
    'has_password', coalesce(v_has_password, false),
    'providers', to_jsonb(v_providers)
  );
end;
$$;

revoke all on function public.email_account_status(text) from public, anon, authenticated;
grant execute on function public.email_account_status(text) to service_role;

create table if not exists public.email_check_throttle (
  bucket text primary key,
  window_start timestamptz not null default now(),
  hits integer not null default 0
);

-- No policies, and RLS on: nothing but service_role (which bypasses RLS)
-- should ever touch this table.
alter table public.email_check_throttle enable row level security;

-- Returns true when the caller is ALLOWED to proceed, false when throttled.
-- Fixed window rather than a sliding one: a scraper's practical throughput is
-- what matters here, not precision at the window edge, and a fixed window is
-- one upsert instead of a row per request.
create or replace function public.email_check_allowed(
  client_bucket text,
  max_hits integer default 20,
  window_seconds integer default 60
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hits integer;
begin
  insert into public.email_check_throttle as t (bucket, window_start, hits)
  values (client_bucket, now(), 1)
  on conflict (bucket) do update
    set
      -- Window expired -> start a fresh one; otherwise keep counting.
      window_start = case
        when now() - t.window_start >= make_interval(secs => window_seconds) then now()
        else t.window_start
      end,
      hits = case
        when now() - t.window_start >= make_interval(secs => window_seconds) then 1
        else t.hits + 1
      end
  returning t.hits into v_hits;

  return v_hits <= max_hits;
end;
$$;

revoke all on function public.email_check_allowed(text, integer, integer) from public, anon, authenticated;
grant execute on function public.email_check_allowed(text, integer, integer) to service_role;

-- Housekeeping: the table only ever needs rows for live windows. Called from
-- the same cron that drains product_image_cache would be overkill, so this is
-- just here for a future sweep if the table ever grows enough to matter.
comment on table public.email_check_throttle is
  'Rate-limit buckets for the check-email edge function. Rows older than their window are dead weight and safe to delete at any time.';
