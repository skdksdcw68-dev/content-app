/**
 * Offline proof of the rate card and the usage meter: no key, no network,
 * nothing spent.
 *
 *   npx tsx scripts/rate-card-check.ts
 *
 * Prints what every house model takes from each plan's month, as the % the app
 * shows, and FAILS (exit 1) if any of these is wrong:
 *   - a price is not a whole number of cents (then the phone's share and the
 *     server's units could round apart);
 *   - a price is not a whole number of meter units;
 *   - a quote is below what fal charges us;
 *   - a plan's budget is more than it earns in its worst month -- every % spent
 *     at cost, on its cheapest billing (yearly), after Apple's 30%. That is the
 *     "subscriptions will never put us in shortage" rule (Netro, 18 Oct 2026),
 *     with Apple at its higher cut so the rule holds either way.
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

/** The budgets in migration 0079, in units, and what each plan pays us. */
const PLANS = [
  { name: "Pro", units: 80_000, monthly: 29.99, yearly: 249.99 },
  { name: "Max", units: 240_000, monthly: 79.99, yearly: 649.99 },
  { name: "Ultra", units: 640_000, monthly: 199.99, yearly: null },
];
const migration = read("supabase/migrations/0079_usage_meter.sql");

let failures = 0;
const fail = (message: string) => {
  failures++;
  console.log(`  ✗ ${message}`);
};

for (const plan of PLANS) {
  if (!migration.includes(`monthly_credits = ${plan.units},`)) {
    fail(`${plan.name}: ${plan.units} units is not what 0079 sets`);
  }
  const budget = plan.units * UNIT;
  const cheapest = Math.min(plan.monthly, plan.yearly === null ? Infinity : plan.yearly / 12);
  const worst = cheapest * 0.7 - budget;
  console.log(`${plan.name}: budget $${budget.toFixed(2)}, worst month at Apple 30% leaves $${worst.toFixed(2)}`);
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

  const cents = quote.amount * 100;
  if (Math.abs(cents - Math.round(cents)) > 1e-6) fail(`${model.label}: ${quote.amount} is not whole cents`);
  const units = quote.amount / UNIT;
  if (Math.abs(units - Math.round(units)) > 1e-6) fail(`${model.label}: ${quote.amount} is not whole units`);
  const ours = quote.ours ?? 0;
  if (quote.amount + 1e-9 < ours) fail(`${model.label}: charges ${quote.amount}, below our cost ${ours}`);

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
