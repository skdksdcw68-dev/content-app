/**
 * The plan caps, enforced where the cost happens. The database decides
 * (consume_quota / effective_plan, migration 0051); this only asks it and
 * turns "no" into a 402 the app recognises and answers with the paywall.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { PublicError } from "./http.ts";

/** HTTP 402: the app shows Autocast Pro when it sees this status. */
export const NEEDS_PRO = 402;

export async function requireQuota(
  admin: SupabaseClient,
  userId: string,
  kind: "ai_write" | "chat" | "video_gen" | "image_gen",
  message: string,
): Promise<void> {
  const { data, error } = await admin.rpc("consume_quota", { p_user: userId, p_kind: kind, p_units: 1 });
  if (error) {
    console.error("consume_quota", error.message);
    // A broken counter must not take the product down with it -- but that is
    // only true while the cost is the person's own. On the house generator
    // (migration 0068) an uncounted call is our money, and failing open would
    // turn one bad minute in the database into an unbounded bill.
    if (kind === "video_gen" || kind === "image_gen") {
      throw new PublicError(
        "We couldn't check your allowance just now. Try again in a moment.",
        503,
        true,
        "quota_unreadable",
      );
    }
    return;
  }
  if (data !== true) throw new PublicError(message, NEEDS_PRO, false, "needs_pro");
}

/** The longest plan this person's plan allows. */
export async function maxPlanDays(admin: SupabaseClient, userId: string): Promise<number> {
  const { data: plan } = await admin.rpc("effective_plan", { p_user: userId });
  const { data } = await admin.from("plans_catalog").select("max_plan_days").eq("code", plan ?? "free").maybeSingle();
  return data?.max_plan_days ?? 7;
}
