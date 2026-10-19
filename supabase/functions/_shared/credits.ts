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
 * Netro, 18 Oct 2026: count it in % "like claude and chatgpt", with OpenAI and
 * fal drawing on the same 100. So a "credit" is now one unit of a usage meter,
 * $0.0001 of the rate card's price (migration 0079), and nobody sees one: the
 * app shows the month as a %. Each model still carries its own markup over
 * what the provider charges us (fal.ts `billable`); the adapter does the
 * multiplying, so this file only turns a price into units. A plan is a
 * monthly budget of them, sized so no plan can cost more than it earns.
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

import { CREDIT_USD } from "./usage.ts";
export { CREDIT_USD };

/** What a job is assumed to cost when nothing can say. Deliberately high: it is
 *  settled to the real charge when the provider gives one, and a person who
 *  cannot afford the guess is told so rather than charged a surprise. */
const UNPRICED: Record<string, number> = {
  video_generation: 30_000,
  image_generation: 2_000,
  audio_generation: 1_000,
  voice_generation: 1_000,
};

const TIER_NAMES = ["Free", "Pro", "Max", "Ultra"];
/** How much each plan gives next to Pro, as the refusal sentence says it.
 *  Kept equal to `plans_catalog` (0082: $15, $45, $125). */
const USAGE = ["", "", "3×", "8.3×"];

/** A price in dollars as meter units. The adapter hands over whole cents, so
 *  this is exact, and the phone's share (price / budget) is the share taken. */
export function creditsFor(cost: Cost | null | undefined): number | null {
  if (!cost || cost.unit !== "usd" || typeof cost.amount !== "number" || !(cost.amount >= 0)) return null;
  return Math.max(1, Math.round(cost.amount / CREDIT_USD));
}

/** A share of the month the way people read one: "under 1%", "4%", "100%". */
export function percentText(units: number, allowance: number): string {
  if (!(allowance > 0)) return "100%";
  const share = (100 * units) / allowance;
  if (share > 0 && share < 1) return "under 1%";
  return `${Math.round(share)}%`;
}

/** "18 Nov": when the meter fills up again. */
function dayText(iso: unknown): string | null {
  const when = typeof iso === "string" ? new Date(iso) : null;
  if (!when || Number.isNaN(when.getTime())) return null;
  return when.toLocaleDateString("en-GB", { day: "numeric", month: "short", timeZone: "UTC" });
}

/** What to say when the month is used up, or a job needs more than is left. */
function upsell(tier: number, resetsAt: unknown): string {
  const day = dayText(resetsAt);
  const back = day ? `It fills up again on ${day}.` : "It fills up again next month.";
  if (tier >= 3) return back;
  if (tier === 0) return "Pick a plan to keep going.";
  return `${back} ${TIER_NAMES[tier + 1]} gives you ${USAGE[tier + 1]} the usage of Pro.`;
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
  // Kling. Making anything at all is a paid feature -- "there is no free
  // trial for any new users. They only get paid things" (2 Oct 2026). Free's
  // small budget is for chat only. A model's own `minTier` can raise it.
  const wanted = Number(candidate?.metadata?.minTier);
  const minTier = Math.max(1, Number.isFinite(wanted) ? wanted : 1);
  if (standing.tier < minTier) {
    const label = candidate?.label ?? "That model";
    throw new PublicError(
      minTier <= 1
        ? `${capability === "image_generation" ? "Pictures are" : "Video is"} part of Autocast Pro. Pick a plan and I'll make it.`
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

  // Named for what it pays for, so the Usage screen can say where the month
  // went (0081): "gen:video_generation:<id>".
  const ref = `gen:${capability}:${crypto.randomUUID()}`;
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

  const answer = (data ?? {}) as { left?: number; limit?: number; resets_at?: string };
  const left = Number(answer.left ?? 0);
  const limit = Number(answer.limit ?? 0);
  const tier = standing?.tier ?? 0;
  throw new PublicError(
    left <= 0
      ? `You've used all of this month's usage. ${upsell(tier, answer.resets_at)}`
      : `That needs about ${percentText(credits, limit)} of your month and you have ${percentText(left, limit)} left. ${upsell(tier, answer.resets_at)}`,
    402,
    false,
    "needs_credits",
  );
}

/** Reads the meter without spending: a zero spend answers with the standing. */
async function meter(admin: SupabaseClient, userId: string) {
  const { data, error } = await admin.rpc("spend_credits", {
    p_user: userId,
    p_amount: 0,
    p_ref: "check",
    p_strict: true,
  });
  return { error, answer: (data ?? {}) as { ok?: boolean; left?: number; limit?: number; resets_at?: string } };
}

/**
 * Stops an AI call before it is made when this month's usage is gone. The
 * call's real cost is taken afterwards, from its tokens (`recordUsage`), so a
 * last reply can run a fraction of a cent past 100% -- never further, because
 * the next one is refused here.
 *
 * Fails OPEN on a counter it cannot read, unlike generation: an AI reply costs
 * a tenth of a cent, and a broken counter should not take the whole app down
 * for that. A video costs dollars, and `reserveCredits` fails closed.
 */
export async function requireUsage(admin: SupabaseClient, userId: string): Promise<void> {
  const { error, answer } = await meter(admin, userId);
  if (error) {
    console.error("requireUsage", error.message);
    return;
  }
  if (answer.ok !== false) return;
  const standing = await standingOf(admin, userId);
  throw new PublicError(
    standing.tier === 0
      ? "You've used this month's free messages. Pick a plan to keep going."
      : `You've used all of this month's usage. ${upsell(standing.tier, answer.resets_at)}`,
    402,
    false,
    standing.tier === 0 ? "needs_pro" : "needs_credits",
  );
}

/** One line for the chat to answer "how much do I have left" from. */
export async function usageLine(admin: SupabaseClient, userId: string): Promise<string> {
  const { error, answer } = await meter(admin, userId);
  if (error) return "Autocast usage: could not be read just now.";
  const limit = Number(answer.limit ?? 0);
  const left = Number(answer.left ?? 0);
  const standing = await standingOf(admin, userId);
  const day = dayText(answer.resets_at);
  return `Autocast usage this month (${standing.name} plan): ${percentText(limit - left, limit)} used, ` +
    `${percentText(left, limit)} left${day ? `, fills up again on ${day}` : ""}. ` +
    "Chat, plans and captions take a small share; pictures and videos take more, and the share is shown before anything is made.";
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
