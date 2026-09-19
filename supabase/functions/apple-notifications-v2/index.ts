/**
 * App Store Server Notifications V2: renewals, failed payments, expiries and
 * refunds, from Apple, without the app being open.
 *
 * The body is a signed JWS whose certificate chain is verified back to
 * Apple's root (see _shared/apple-jws.ts), and so is the transaction inside
 * it. Anything that does not verify is answered 200 and ignored -- a
 * non-200 makes Apple retry, and a forgery should not earn retries.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json } from "../_shared/http.ts";
import { verifyAppleJWS, type AppleTransaction } from "../_shared/apple-jws.ts";
import { applyTransaction, BUNDLE_ID, PRODUCTS } from "../_shared/subscription.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

interface Notification {
  notificationType: string;
  subtype?: string;
  data?: {
    bundleId?: string;
    signedTransactionInfo?: string;
    signedRenewalInfo?: string;
  };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const { signedPayload } = (await request.json()) as { signedPayload?: string };
    if (!signedPayload) return json({ ignored: "no payload" });

    const note = await verifyAppleJWS<Notification>(signedPayload);
    if (note.data?.bundleId !== BUNDLE_ID || !note.data.signedTransactionInfo) return json({ ignored: "not ours" });

    const tx = await verifyAppleJWS<AppleTransaction>(note.data.signedTransactionInfo);
    if (!PRODUCTS.has(tx.productId)) return json({ ignored: "unknown product" });

    const renewal = note.data.signedRenewalInfo
      ? await verifyAppleJWS<{ autoRenewStatus?: number }>(note.data.signedRenewalInfo).catch(() => null)
      : null;

    // Who: the user id the app put on the purchase, else whoever already
    // holds this subscription.
    let userId = tx.appAccountToken ?? null;
    if (!userId) {
      const { data } = await admin.from("subscriptions")
        .select("user_id").eq("original_transaction_id", tx.originalTransactionId).maybeSingle();
      userId = data?.user_id ?? null;
    }
    if (!userId) return json({ ignored: "unknown subscriber" });

    let status: "active" | "grace" | "expired" | "refunded" | undefined;
    switch (note.notificationType) {
      case "REFUND":
      case "REVOKE":
        status = "refunded";
        break;
      case "EXPIRED":
      case "GRACE_PERIOD_EXPIRED":
        status = "expired";
        break;
      case "DID_FAIL_TO_RENEW":
        status = note.subtype === "GRACE_PERIOD" ? "grace" : "expired";
        break;
      default:
        status = undefined; // SUBSCRIBED, DID_RENEW, OFFER_REDEEMED...: read from the transaction.
    }

    await applyTransaction(admin, userId, tx, {
      status,
      autoRenew: renewal?.autoRenewStatus === undefined ? undefined : renewal.autoRenewStatus === 1,
    });
    return json({ ok: true, type: note.notificationType });
  } catch (error) {
    console.error("apple notification", error instanceof Error ? error.message : error);
    return json({ ignored: "did not verify" });
  }
});
