/**
 * Installs one of Autocast's own generators. Operator tool, not a feature.
 *
 * Abel pasted a fal key on 25 Sep 2026 and it had to go somewhere that is not
 * the repository, not a table in the clear, and not a screenshot. This seals it
 * the same way every other credential is sealed -- bound to the row it belongs
 * to, so moving the ciphertext anywhere else makes it undecryptable rather than
 * usable -- and then proves it by asking the provider what it can do.
 *
 * WHY THIS IS NOT `connect-generator`. That one is the customer path: a user
 * session, Higgsfield only, and it writes to `private.provider_credentials`,
 * which the router does not read. This writes a `connections` row, which is
 * what `capabilities_for` and `route.ts` actually use, and it can mark that row
 * as the house generator. Two different jobs.
 *
 * 🔴 THE GUARD. There is no user session here, so the request must carry
 * `ADMIN_INSTALL_KEY` in `x-admin-key` -- a secret set once with
 * `supabase secrets set` and held nowhere else. Compared in constant time,
 * because a key checked with `===` leaks its length and then its bytes.
 *
 * It is its own secret rather than the service role key, which was the first
 * attempt: that value is injected into functions by the platform and did not
 * match what a caller had, so the guard refused everything including me. A
 * dedicated secret is also the safer shape -- this endpoint should not become
 * a second place the service role key is presented.
 *
 * Unset means closed. A missing secret refuses every request rather than
 * comparing against an empty string and letting anybody in.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { fail, json, preflight, PublicError } from "../_shared/http.ts";
import { seal } from "../_shared/crypto.ts";
import { adapterFor } from "../_shared/connectors/registry.ts";
import { storeDiscovery } from "../_shared/connectors/discovery.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ADMIN_KEY = Deno.env.get("ADMIN_INSTALL_KEY") ?? "";

interface Body {
  provider?: string;
  key?: string;
  label?: string;
  /** The account the connection hangs off. Never signed into. */
  user_id?: string;
  /** Make it the house generator once it works. */
  house?: boolean;
}

function sameSecret(given: string, expected: string): boolean {
  if (given.length !== expected.length) return false;
  let difference = 0;
  for (let i = 0; i < given.length; i++) difference |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  return difference === 0;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  if (ADMIN_KEY === "" || !sameSecret(request.headers.get("x-admin-key") ?? "", ADMIN_KEY)) {
    return json({ error: "no" }, 401);
  }

  try {
    const body = (await request.json().catch(() => ({}))) as Body;
    const slug = (body.provider ?? "").trim();
    const key = (body.key ?? "").trim();
    const userId = (body.user_id ?? "").trim();
    if (!slug || !key || !userId) throw new PublicError("provider, key and user_id are all required.");

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    const { data: provider } = await admin
      .from("providers")
      .select("id, slug, auth_kind, api_base, mcp_url")
      .eq("slug", slug)
      .maybeSingle();
    if (!provider) throw new PublicError(`unknown provider ${slug}`, 404);

    const authKind = provider.auth_kind ?? "api_key";

    // The row first: the ciphertext is bound to the row's own id.
    const { data: connectionId, error: beginError } = await admin.rpc("begin_connection", {
      p_user: userId,
      p_provider_slug: slug,
    });
    if (beginError) throw beginError;

    // The same AAD `tokens.ts` opens an api_key connection with. Getting this
    // wrong fails to decrypt rather than decrypting something wrong, which is
    // the whole reason the binding exists.
    const aad = authKind === "api_key" ? `${connectionId}:provider` : `${connectionId}:access`;
    const sealed = await seal(key, aad);
    const { error: secretError } = await admin.rpc("store_connection_secret", {
      p_connection: connectionId,
      p_access_ct: sealed,
    });
    if (secretError) throw secretError;

    // Proved before it is kept, and before it is shared with anybody. A
    // credential stored without being tried is one that fails inside a job at
    // three in the morning.
    const endpoint = authKind === "api_key"
      ? (provider.api_base ?? "")
      : (provider.mcp_url ?? provider.api_base ?? "");
    const adapter = adapterFor(slug, authKind);

    let discovery;
    try {
      discovery = await adapter.discover({ connectionId, secret: key, endpoint });
    } catch (thrown) {
      await admin.rpc("fault_connection", {
        p_connection: connectionId,
        p_code: "bad_key",
        p_status: "error",
      });
      throw new PublicError(
        `${slug} refused it: ${thrown instanceof Error ? thrown.message : String(thrown)}`,
        400,
      );
    }

    // Through the same writer every other discovery uses, so the dedupe and
    // the tool list behave identically here.
    const recorded = await storeDiscovery(admin, connectionId, discovery);

    const { error: liveError } = await admin.rpc("activate_connection", {
      p_connection: connectionId,
      p_label: body.label ?? discovery.accountLabel,
      p_external: discovery.externalAccountId,
    });
    if (liveError) throw liveError;

    if (body.house === true) {
      const { error: houseError } = await admin.rpc("set_house_connection", {
        p_connection: connectionId,
        p_is_house: true,
      });
      if (houseError) throw houseError;
    }

    return json({
      connection_id: connectionId,
      provider: slug,
      account: discovery.accountLabel,
      models: recorded,
      house: body.house === true,
    });
  } catch (error) {
    // The real message, not a bare 500. Everything past the guard is an
    // operator, and "Something went wrong on our side" to the person holding
    // the admin key is just a slower way to read the logs -- which this
    // project has no command for.
    if (error instanceof PublicError) return fail(error);
    console.error("install-house-generator", error);
    return json({
      error: error instanceof Error ? error.message : String(error),
      where: error instanceof Error ? (error.stack ?? "").split("\n").slice(0, 4).join(" | ") : null,
    }, 500);
  }
});
