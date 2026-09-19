/**
 * The phone just bought, restored, or launched with a subscription: it sends
 * the signed transactions StoreKit gave it, and this decides whether that
 * makes the person Pro.
 *
 * Nothing the phone says is believed except what Apple signed. The purchase
 * also carries the user's id as its appAccountToken, and a transaction bound
 * to a different Autocast user is refused -- a receipt cannot be shared.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { AppleSignatureError, verifyAppleJWS, type AppleTransaction } from "../_shared/apple-jws.ts";
import { applyTransaction, BUNDLE_ID, PRODUCTS } from "../_shared/subscription.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);
    const asUser = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authorization } } });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const body = (await request.json().catch(() => ({}))) as { transactions?: string[] };
    const signed = (body.transactions ?? []).filter((t) => typeof t === "string").slice(0, 20);
    if (signed.length === 0) throw new PublicError("No transactions sent.");

    let best: AppleTransaction | null = null;
    for (const jws of signed) {
      let tx: AppleTransaction;
      try {
        tx = await verifyAppleJWS<AppleTransaction>(jws);
      } catch (error) {
        if (error instanceof AppleSignatureError) {
          console.warn("rejected transaction:", error.message);
          continue;
        }
        throw error;
      }
      if (tx.bundleId !== BUNDLE_ID || !PRODUCTS.has(tx.productId)) continue;
      if (tx.appAccountToken && tx.appAccountToken.toLowerCase() !== auth.user.id.toLowerCase()) {
        console.warn("transaction bound to another user", tx.originalTransactionId);
        continue;
      }
      if (!best || (tx.expiresDate ?? 0) > (best.expiresDate ?? 0)) best = tx;
    }

    if (!best) throw new PublicError("Apple couldn’t confirm that purchase.", 422);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const result = await applyTransaction(admin, auth.user.id, best);
    return json({ ok: true, ...result });
  } catch (error) {
    return fail(error);
  }
});
