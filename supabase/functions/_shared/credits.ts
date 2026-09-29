/**
 * Credits: what making something costs, in the unit people are metered by.
 *
 * Netro, 29 Sep 2026: "we do need to provide a pricing things as well, like we
 * can split it, pro, max and 1 more so they choose and subscribe."
 *
 * 🔴 Until this existed, a picture or a video made in chat was not counted at
 * all. Plan caps guarded scheduled posts and chat MESSAGES; the `generate`
 * action called neither, so a free account could make images without limit
 * (tested) and a Pro one could have made a thousand Veo videos. Counting
 * things was never going to be right anyway -- a Wan clip costs us $0.25 and a
 * Veo one with sound $3.20, and both were "one video".
 *
 * One credit is a tenth of a cent of what the provider charges us, which is
 * also the number the generator bar has shown beside the send button since
 * 26 Sep. A plan is a monthly allowance of them (migration 0077).
 *
 * The rules, and why each is there:
 *   - Spent BEFORE the job starts. A job that discovers it was over budget
 *     has already cost the money.
 *   - Only when the job runs on OUR money (the house generator). Somebody who
 *     connected their own generator is paying for it themselves.
 *   - Given back when the job fails, by a trigger on the table, so every road
 *     that ends a run is covered -- including the reaper that kills a run
 *     whose worker died three times.
 *   - Settled to the provider's own charge when the job succeeds, because the
 *     price quoted and the price charged can differ by a few credits, and the
 *     router may have fallen back to another model.
 *   - Fails CLOSED. A counter that cannot be read stops the job: an uncounted
 *     call is our bill.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { PublicError } from "./http.ts";
import { candidatesFor, quoteFor } from "./connectors/route.ts";
import type { Capability, Cost } from "./connectors/contract.ts";

/** One credit is a tenth of a cent of what the provider charges us. */
export const CREDIT_USD = 0.001;

/** What a job is assumed to cost when nothing can say. Deliberately high: it is
 *  settled to the real charge when the provider gives one, and a person who
 *  cannot afford the guess is told so rather than charged a surprise. */
const UNPRICED: Record<string, number> = {
  video_generation: 800,
  image_generation: 150,
  audio_generation: 100,
  voice_generation: 100,
};

const TIER_NAMES = ["Free", "Pro", "Max", "Ultra"];
const ALLOWANCES = ["100", "8,000", "26,000", "70,000"];

/** A price in dollars as credits. The rounding is the app's own
 *  (`GenerateChoices.credits`), so the number on the send button is the number
 *  taken. */
export function creditsFor(cost: Cost | null | undefined): number | null {
  if (!cost || cost.unit !== "usd" || typeof cost.amount !== "number" || !(cost.amount >= 0)) return null;
  return Math.max(1, Math.round(cost.amount / CREDIT_USD));
}

export interface Standing {
  plan: string;
  tier: number;
  name: string;
}

/** The plan this person is on right now, and how high it ranks. */
export async function standingOf(admin: SupabaseClient, userId: string): Promise<Standing> {
  const { data: plan } = await admin.rpc("effective_plan", { p_user: userId });
  const code = (typeof plan === "string" ? plan : null) ?? "free";
  const { data } = await admin.from("plans_catalog").select("display_name, tier").eq("code", code).maybeSingle();
  return { plan: code, tier: data?.tier ?? 0, name: data?.display_name ?? "Free" };
}

export interface Charge {
  /** What the spend and any refund are recorded under. */
  ref: string;
  credits: number;
  model: string | null;
}

/**
 * Charges for one generation, when it will run on our money. Null when it will
 * not (their own connection). Throws a 402 the app answers with the paywall.
 */
export async function chargeForGeneration(
  admin: SupabaseClient,
  userId: string,
  input: Record<string, unknown>,
): Promise<Charge | null> {
  const capability = String(input.capability ?? "video_generation") as Capability;

  const { data: ours } = await admin.rpc("uses_house_generator", { p_user: userId, p_capability: capability });
  if (ours !== true) return null;

  const mine = await candidatesFor(admin, userId, capability);
  const named = typeof input.model === "string" ? input.model : null;
  const candidate = (named ? mine.find((c) => c.externalId === named) : undefined) ?? mine[0];
  const standing = await standingOf(admin, userId);

  // Some models are for higher plans: Veo with sound, Seedance 2.5, a 4K
  // Kling. Video at all is a paid feature. A model's own `minTier` wins.
  const wanted = Number(candidate?.metadata?.minTier);
  const minTier = Number.isFinite(wanted) ? wanted : capability === "video_generation" ? 1 : 0;
  if (standing.tier < minTier) {
    const label = candidate?.label ?? "That model";
    throw new PublicError(
      minTier <= 1
        ? "Video is part of Autocast Pro. Pick a plan and I'll make it."
        : `${label} is on ${TIER_NAMES[Math.min(minTier, 3)]}. Your ${standing.name} plan can use the others.`,
      402,
      false,
      minTier <= 1 ? "needs_pro" : "needs_tier",
    );
  }

  let credits: number | null = null;
  if (candidate) {
    const settings = (input.settings ?? {}) as Record<string, unknown>;
    const cost = await quoteFor(admin, {
      connectionId: candidate.connectionId,
      capability,
      model: candidate.externalId,
      prompt: String(input.prompt ?? "").slice(0, 600) || "a picture",
      options: { aspect_ratio: "9:16", ...settings },
      metadata: candidate.metadata,
    });
    credits = creditsFor(cost);
  }
  credits ??= UNPRICED[capability] ?? 200;

  const ref = crypto.randomUUID();
  await reserveCredits(admin, userId, credits, ref, standing);
  return { ref, credits, model: candidate?.externalId ?? null };
}

/** Takes the credits, or throws the 402 that says what is missing. */
export async function reserveCredits(
  admin: SupabaseClient,
  userId: string,
  credits: number,
  ref: string,
  standing?: Standing,
): Promise<void> {
  const { data, error } = await admin.rpc("spend_credits", {
    p_user: userId,
    p_amount: credits,
    p_ref: ref,
    p_strict: true,
  });
  if (error) {
    console.error("spend_credits", error.message);
    throw new PublicError(
      "We couldn't check your credits just now. Try again in a moment.",
      503,
      true,
      "credits_unreadable",
    );
  }
  if ((data as { ok?: boolean } | null)?.ok === true) return;

  const left = Number((data as { left?: number } | null)?.left ?? 0);
  const tier = standing?.tier ?? 0;
  const money = (n: number) => n.toLocaleString("en-US");
  const next = tier >= 3
    ? "They come back on the 1st."
    : `${TIER_NAMES[tier + 1]} has ${ALLOWANCES[tier + 1]} a month.`;
  throw new PublicError(
    `That needs ${money(credits)} credits and you have ${money(left)} left this month. ${next}`,
    402,
    false,
    "needs_credits",
  );
}

/** Gives back everything a reference spent. Idempotent. */
export async function refundCredits(admin: SupabaseClient, userId: string, ref: string): Promise<void> {
  const { error } = await admin.rpc("refund_spend", { p_user: userId, p_ref: ref });
  if (error) console.error("refund_spend", error.message);
}

/**
 * A job succeeded: make what was taken match what the provider charged. The
 * router can fall back to a dearer model than the one quoted, and a quote is an
 * estimate; the difference is small and goes whichever way it goes.
 */
export async function settleCredits(
  admin: SupabaseClient,
  userId: string,
  ref: string | null | undefined,
  reserved: number | null | undefined,
  charged: Cost | null | undefined,
): Promise<void> {
  if (!ref || !reserved) return;
  const actual = creditsFor(charged);
  if (actual === null || actual === reserved) return;
  const delta = actual - reserved;
  const { error } = delta > 0
    ? await admin.rpc("spend_credits", { p_user: userId, p_amount: delta, p_ref: `${ref}:extra`, p_strict: false })
    : await admin.rpc("give_back_credits", { p_user: userId, p_amount: -delta, p_ref: `${ref}:back` });
  if (error) console.error("settle credits", error.message);
}
