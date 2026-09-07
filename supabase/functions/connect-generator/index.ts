/**
 * Connecting a generator you pay for.
 *
 * The key never touches the database in the clear and never comes back out to
 * the app. What the app can see afterwards is that a generator exists, when it
 * was last checked, and whether it worked -- which is `my_generators()`.
 *
 * The probe is not optional. A credential stored without being tried is one
 * that fails inside a job at three in the morning, where the error reads as the
 * model being broken rather than as a key nobody verified. It costs one
 * unauthenticated-shaped request and no generation.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { seal } from "../_shared/crypto.ts";
import { parseCredential, probe } from "../_shared/higgsfield.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

interface Body {
  provider?: string;
  label?: string;
  key_id?: string;
  key_secret?: string;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);

    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const body = (await request.json().catch(() => ({}))) as Body;
    const provider = (body.provider ?? "higgsfield").trim();

    if (provider !== "higgsfield") {
      throw new PublicError(`${provider} is not supported yet.`, 400);
    }

    const keyId = (body.key_id ?? "").trim();
    const keySecret = (body.key_secret ?? "").trim();
    if (!keyId || !keySecret) throw new PublicError("Both the key id and the secret are needed.");

    const credential = parseCredential(`${keyId}:${keySecret}`);

    // Tried before it is kept. A key that does not work is refused here rather
    // than stored and discovered later.
    const result = await probe(credential);
    if (!result.ok) throw new PublicError(result.detail, 400);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // The row first, because the ciphertext is bound to the row's own id --
    // moving a sealed value into somebody else's row makes it undecryptable
    // rather than usable.
    const { data: credentialId, error: beginError } = await admin.rpc("begin_provider_credential", {
      p_user: auth.user.id,
      p_provider: provider,
      p_label: (body.label ?? "").trim(),
    });
    if (beginError) throw beginError;

    const sealed = await seal(`${keyId}:${keySecret}`, `${credentialId}:provider`);

    const { error: setError } = await admin.rpc("set_provider_secret", {
      p_credential_id: credentialId,
      p_secret_ct: sealed,
      p_ok: true,
      p_detail: result.detail,
    });
    if (setError) throw setError;

    return json({ credential_id: credentialId, provider, probe: result.detail });
  } catch (error) {
    return fail(error);
  }
});
