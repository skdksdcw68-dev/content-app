/**
 * The phone just bought, restored, or launched with a subscription: it sends
 * the signed transactions StoreKit gave it, and this decides whether that
 * makes the person Pro.
 *
 * Nothing the phone says is believed except what Apple signed. The purchase
 * also carries the user's id as its appAccountToken, and a transaction bound
 * to a different Autocast user is refused -- a receipt cannot be shared.
 *
 * 🔴 But "a different user" is not the same as "a different id". Autocast signs
 * people in ANONYMOUSLY first. Somebody who buys while anonymous and then signs
 * in with Apple keeps a receipt stamped with the old anonymous id forever, and
 * a plain id comparison refuses it every time from then on -- silently, because
 * the phone sends with announce: false. Restore cannot fix it either; it fails
 * the same way. Abel suspected exactly this on 25 Sep 2026: "the subscription
 * thing also might doesn't work when you subscribe."
 *
 * So the test is ownership, not equality. A receipt belongs here when its token
 * is this user, OR when nobody else has ever claimed that original transaction.
 * A receipt genuinely claimed by somebody else is still refused, which is the
 * part that matters.
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

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    /** Whether this receipt is this person's to claim. */
    const belongsHere = async (tx: AppleTransaction, userId: string): Promise<boolean> => {
      const token = tx.appAccountToken?.toLowerCase();
      if (!token || token === userId.toLowerCase()) return true;

      // Bought under another id. Only somebody else having already claimed it
      // makes it theirs -- an id this account has since grown out of has not.
      const { data } = await admin
        .from("subscriptions")
        .select("user_id")
        .eq("original_transaction_id", tx.originalTransactionId)
        .maybeSingle();

      if (!data) return true;
      return String(data.user_id).toLowerCase() === userId.toLowerCase();
    };

    const rejected: string[] = [];
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
      if (!(await belongsHere(tx, auth.user.id))) {
        rejected.push(tx.originalTransactionId);
        continue;
      }
      if (!best || (tx.expiresDate ?? 0) > (best.expiresDate ?? 0)) best = tx;
    }

    if (!best) {
      if (rejected.length > 0) {
        console.warn("receipts claimed by another account:", rejected.join(", "));
        throw new PublicError(
          "That subscription belongs to a different Autocast account. Sign in to that one to use it.",
          409,
        );
      }
      throw new PublicError("Apple couldn’t confirm that purchase.", 422);
    }

    const result = await applyTransaction(admin, auth.user.id, best);
    return json({ ok: true, ...result });
  } catch (error) {
    return fail(error);
  }
});
