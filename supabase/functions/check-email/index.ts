// Pre-auth "does this email have an account, and how does it sign in?"
// check, called from app/(onboarding)/email.tsx before the user reaches the
// password screen. Lets sign-up recognise a returning user ("Welcome back")
// and sign-in reject an unregistered email immediately, instead of both
// failing later behind Supabase's deliberately-vague messaging.
//
// No session exists at this point in the flow, so this can't be gated behind
// supabase.auth.getUser() like the other functions here - it's reachable with
// the anon key, same as signUp/signInWithPassword themselves already are.
//
// Backed by the public.email_account_status RPC (see the migration), which is
// a single indexed lookup on auth.users.email and is granted ONLY to
// service_role - the client can never call it directly. Replaced an earlier
// version of this function that paginated the whole admin user list on every
// call; that was correct but walked every page over HTTP, and got slower with
// every new signup.
//
// Two approaches were tried and rejected before that one, worth not
// re-attempting: GET /admin/users?email=... silently IGNORES the email filter
// and returns everyone; POST /admin/generate_link reports email_exists
// cleanly but CREATES a real persisted account as a side effect when the
// email is new - fatal for a probe that fires on most "Continue" taps.
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

// Rate limiting lives in Postgres (public.email_check_allowed), NOT in this
// file. An in-memory Map here was tried first and measured as a complete
// no-op: 25 rapid requests all returned 200, because each call is served by a
// fresh short-lived isolate with an empty map. See the throttle migration for
// the full note.
const RATE_LIMIT_MAX = 20;
const RATE_LIMIT_WINDOW_SECONDS = 60;

async function isAllowed(supabaseUrl: string, serviceRoleKey: string, bucket: string): Promise<boolean> {
  const res = await fetch(`${supabaseUrl}/rest/v1/rpc/email_check_allowed`, {
    method: 'POST',
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      client_bucket: bucket,
      max_hits: RATE_LIMIT_MAX,
      window_seconds: RATE_LIMIT_WINDOW_SECONDS,
    }),
  });
  // Fail OPEN on a throttle-infrastructure error: a broken rate limiter must
  // not take sign-up/sign-in down with it. The thing being protected here is
  // enumeration convenience, not correctness or money.
  if (!res.ok) {
    console.error(`email_check_allowed failed (${res.status}) - allowing request`);
    return true;
  }
  return (await res.json()) !== false;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!serviceRoleKey) {
    console.error('SUPABASE_SERVICE_ROLE_KEY secret is not set');
    return jsonResponse({ error: 'check_failed' }, 502);
  }

  const ip = req.headers.get('x-forwarded-for')?.split(',')[0].trim() || 'unknown';
  // Logged once so it's verifiable from the function logs that this is a real
  // per-caller bucket and not everyone sharing 'unknown' (which would throttle
  // legitimate users collectively).
  console.log(`check-email from ip=${ip}`);
  if (!(await isAllowed(supabaseUrl, serviceRoleKey, `ip:${ip}`))) {
    return jsonResponse({ error: 'rate_limited' }, 429);
  }

  let body: { email?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid_request' }, 400);
  }

  const email = typeof body.email === 'string' ? body.email.trim() : '';
  if (!email || !email.includes('@')) {
    return jsonResponse({ error: 'invalid_request' }, 400);
  }

  try {
    // Calling the RPC over PostgREST directly rather than pulling in the
    // supabase-js client for one query - fewer moving parts, and this
    // function has no other database work to do.
    const res = await fetch(`${supabaseUrl}/rest/v1/rpc/email_account_status`, {
      method: 'POST',
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ check_email: email }),
    });
    if (!res.ok) {
      console.error(`email_account_status failed (${res.status}):`, await res.text());
      return jsonResponse({ error: 'check_failed' }, 502);
    }
    const status = (await res.json()) as { exists?: boolean; has_password?: boolean; providers?: string[] };
    return jsonResponse({
      exists: !!status.exists,
      hasPassword: !!status.has_password,
      providers: Array.isArray(status.providers) ? status.providers : [],
    });
  } catch (err) {
    console.error('check-email failed:', err);
    return jsonResponse({ error: 'check_failed' }, 502);
  }
});
