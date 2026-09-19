/**
 * Turning a verified Apple transaction into the person's subscription row.
 * Shared by verify-purchase (the phone, right after buying or restoring) and
 * apple-notifications-v2 (Apple, on renewals, expiries and refunds).
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import type { AppleTransaction } from "./apple-jws.ts";

export const BUNDLE_ID = "Autocast";
export const PRODUCTS = new Set(["autocast.pro.monthly", "autocast.pro.yearly"]);

export async function applyTransaction(
  admin: SupabaseClient,
  userId: string,
  tx: AppleTransaction,
  extra: { status?: "active" | "grace" | "expired" | "refunded"; autoRenew?: boolean } = {},
): Promise<{ status: string; expiresAt: string | null; isTrial: boolean }> {
  const expires = tx.expiresDate ? new Date(tx.expiresDate) : null;
  const revoked = !!tx.revocationDate;
  const status = extra.status
    ?? (revoked ? "refunded" : expires && expires.getTime() > Date.now() ? "active" : "expired");
  // offerType 1 = introductory offer; with no discount type it is the free trial.
  const isTrial = tx.offerType === 1 && (tx.offerDiscountType ?? "FREE_TRIAL") === "FREE_TRIAL";

  const row: Record<string, unknown> = {
    user_id: userId,
    plan_code: "creator",
    provider: "apple",
    original_transaction_id: tx.originalTransactionId,
    status,
    current_period_start: new Date(tx.purchaseDate).toISOString(),
    current_period_end: expires?.toISOString() ?? null,
    product_id: tx.productId,
    is_trial: isTrial,
    environment: tx.environment ?? null,
    updated_at: new Date().toISOString(),
  };
  if (extra.autoRenew !== undefined) row.auto_renew = extra.autoRenew;

  // A manual owner grant is never overwritten by an Apple row.
  const { data: current } = await admin.from("subscriptions").select("provider").eq("user_id", userId).maybeSingle();
  if (current?.provider === "manual") {
    return { status: "active", expiresAt: null, isTrial: false };
  }

  const { error } = await admin.from("subscriptions").upsert(row, { onConflict: "user_id" });
  if (error) throw error;
  return { status, expiresAt: row.current_period_end as string | null, isTrial };
}
