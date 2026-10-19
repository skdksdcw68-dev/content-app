/**
 * Offline proof of the rate card and the usage meter: no key, no network,
 * nothing spent.
 *
 *   npx tsx scripts/rate-card-check.ts
 *
 * Prints what every house model takes from each plan's month, as the % the app
 * shows, and FAILS (exit 1) if any of these is wrong:
 *   - a price is not a whole number of meter units ($0.0001);
 *   - a price is not EXACTLY what fal charges us, rounded up to one unit at
 *     most (Netro, 19 Oct 2026: "deduct the exact cost" -- no markup);
 *   - fal.ts and usage.ts disagree on the meter unit;
 *   - a plan's budget is more than it earns in its worst month -- every % spent
 *     at cost, on its cheapest billing (yearly), after Apple's 15% (the Small
 *     Business rate Netro is on; 0082 sizes the plans for it). That is the
 *     "subscriptions will never put us in shortage" rule (Netro, 18 Oct 2026).
 *
 * Netro, 18 Oct 2026: "count with % like claude and chatgpt", OpenAI and fal
 * drawing from the same 100.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describeCatalogue, falAdapter } from "../supabase/functions/_shared/connectors/fal.ts";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (file: string) => fs.readFileSync(path.join(REPO, file), "utf8");

const unitMatch = /export const CREDIT_USD = ([0-9.]+);/.exec(read("supabase/functions/_shared/usage.ts"));
if (!unitMatch) throw new Error("no CREDIT_USD in usage.ts");
const UNIT = Number(unitMatch[1]);
const falUnit = /const METER_UNIT_USD = ([0-9.]+);/.exec(read("supabase/functions/_shared/connectors/fal.ts"));

/** The budgets in migration 0082, in units, and what each plan pays us. */
const PLANS = [
  { name: "Pro", units: 150_000, monthly: 29.99, yearly: 249.99 },
  { name: "Max", units: 450_000, monthly: 79.99, yearly: 649.99 },
  { name: "Ultra", units: 1_250_000, monthly: 199.99, yearly: null },
];
const migration = read("supabase/migrations/0082_plan_sizes.sql");

let failures = 0;
const fail = (message: string) => {
  failures++;
  console.log(`  ✗ ${message}`);
};

if (!falUnit || Number(falUnit[1]) !== UNIT) fail(`fal.ts METER_UNIT_USD ${falUnit?.[1]} is not usage.ts CREDIT_USD ${UNIT}`);

for (const plan of PLANS) {
  if (!new RegExp(`monthly_credits = ${plan.units}\\s`).test(migration)) {
    fail(`${plan.name}: ${plan.units} units is not what 0082 sets`);
  }
  const budget = plan.units * UNIT;
  const cheapest = Math.min(plan.monthly, plan.yearly === null ? Infinity : plan.yearly / 12);
  const worst = cheapest * 0.85 - budget;
  console.log(`${plan.name}: budget $${budget.toFixed(2)}, worst month at Apple 15% leaves $${worst.toFixed(2)}`);
  if (worst <= 0) fail(`${plan.name} can cost more than it earns`);
}

const pct = (usd: number, units: number) => {
  const share = (100 * usd) / (units * UNIT);
  return share < 1 ? "<1%" : `${share.toFixed(share < 10 ? 1 : 0)}%`;
};

const rows: Array<Record<string, string | number>> = [];
for (const model of describeCatalogue()) {
  const video = model.capability === "video_generation";
  const defaults = ((model.metadata as any)?.constraints?.defaults ?? {}) as Record<string, unknown>;
  const durations: number[] = (model.metadata as any)?.constraints?.durations ?? [];
  // Clips are compared at 5s where the model offers it, else its shortest.
  const length = video ? (durations.includes(5) ? 5 : durations[0] ?? 5) : undefined;

  const quote = await falAdapter.quote!(
    {} as never,
    {
      capability: model.capability,
      model: model.external_id,
      prompt: "check",
      options: video ? { duration: length, resolution: defaults.resolution } : {},
    } as never,
  );
  if (!quote || quote.amount === null) {
    fail(`${model.label}: no quote`);
    continue;
  }

  const units = quote.amount / UNIT;
  if (Math.abs(units - Math.round(units)) > 1e-6) fail(`${model.label}: ${quote.amount} is not whole units`);
  const ours = quote.ours ?? 0;
  if (quote.amount + 1e-9 < ours) fail(`${model.label}: charges ${quote.amount}, below our cost ${ours}`);
  if (quote.amount - ours > UNIT + 1e-9) fail(`${model.label}: charges ${quote.amount}, more than our cost ${ours}`);

  rows.push({
    model: model.label,
    kind: video ? `${length}s clip` : "picture",
    "we pay": `$${ours.toFixed(3)}`,
    "of Pro": pct(quote.amount, PLANS[0].units),
    "of Max": pct(quote.amount, PLANS[1].units),
    "of Ultra": pct(quote.amount, PLANS[2].units),
    "per Pro month": Math.floor((PLANS[0].units * UNIT) / quote.amount),
  });
}

console.table(rows);
if (failures > 0) {
  console.log(`${failures} problem(s)`);
  process.exit(1);
}
console.log("rate card OK");
