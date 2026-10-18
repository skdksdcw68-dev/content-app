/**
 * Recording what each AI call really cost.
 *
 * Prices per 1M tokens from OpenAI's pricing page, checked 19 Sep 2026
 * (developers.openai.com/api/docs/pricing). A model not listed is still
 * recorded with its tokens, and a null cost -- never a guess.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

const PRICES: Record<string, { input: number; output: number }> = {
  "gpt-4.1": { input: 2.0, output: 8.0 },
  "gpt-4.1-mini": { input: 0.4, output: 1.6 },
  "gpt-4.1-nano": { input: 0.1, output: 0.4 },
  "gpt-5": { input: 1.25, output: 10.0 },
  "gpt-5-mini": { input: 0.25, output: 2.0 },
  "gpt-5-nano": { input: 0.05, output: 0.4 },
  "gpt-5.4-mini": { input: 0.75, output: 4.5 },
  "gpt-5.4-nano": { input: 0.2, output: 1.25 },
  "gpt-5.6-luna": { input: 0.2, output: 1.2 },
};

export interface TokenUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
}

export function costUSD(model: string, usage: TokenUsage | null | undefined): number | null {
  // Dated snapshots ("gpt-4.1-mini-2025-04-14") price as their family.
  const key = Object.keys(PRICES)
    .filter((name) => model === name || model.startsWith(`${name}-2`))
    .sort((a, b) => b.length - a.length)[0];
  if (!key || !usage) return null;
  const price = PRICES[key];
  return ((usage.prompt_tokens ?? 0) * price.input + (usage.completion_tokens ?? 0) * price.output) / 1_000_000;
}

/**
 * One unit of the usage meter, in dollars of what a thing costs at the rate
 * card's price (migration 0079). Small enough that a chat reply counts: about
 * nine units of a Pro month's 80,000. People never see a unit -- the app shows
 * the month as a %.
 */
export const CREDIT_USD = 0.0001;

/** Dollars as meter units, rounded up so nothing that cost us is free. */
export function unitsFor(usd: number): number {
  return Math.max(1, Math.ceil(usd / CREDIT_USD - 1e-9));
}

/**
 * Records what one AI call cost, and takes it from the person's usage meter.
 *
 * Netro, 18 Oct 2026: "uses fal or uses open ai it counts from the 100." Until
 * then an OpenAI call was written down here and charged to nobody: chat had a
 * message cap and nothing else, so the OpenAI bill sat outside every plan.
 *
 * Taken AFTER the call, because only then are the tokens known; the gate that
 * stops a call when the month is used up is `requireUsage`, before it. Best
 * effort: a failed write here must never fail the person's request.
 */
export async function recordUsage(
  admin: SupabaseClient,
  row: { userId: string; brandId?: string | null; kind: string; model: string; usage: TokenUsage | null | undefined },
): Promise<void> {
  const cost = costUSD(row.model, row.usage);
  const { error } = await admin.from("usage_events").insert({
    user_id: row.userId,
    brand_id: row.brandId ?? null,
    kind: row.kind,
    units: 1,
    cost_cents: 0,
    model: row.model,
    input_tokens: row.usage?.prompt_tokens ?? null,
    output_tokens: row.usage?.completion_tokens ?? null,
    cost_usd: cost,
  });
  if (error) console.warn("usage not recorded", error.message);
  await takeUsage(admin, row.userId, cost, row.kind);
}

/** Takes what an AI call cost from the person's meter, after the fact. For a
 *  caller that writes its own `usage_events` row. */
export async function takeUsage(
  admin: SupabaseClient,
  userId: string,
  costUsd: number | null,
  kind: string,
): Promise<void> {
  if (costUsd === null || !(costUsd > 0)) return;
  const { error } = await admin.rpc("spend_credits", {
    p_user: userId,
    p_amount: unitsFor(costUsd),
    p_ref: `ai:${kind}:${crypto.randomUUID()}`,
    p_strict: false,
  });
  if (error) console.warn("usage not taken from the meter", error.message);
}
