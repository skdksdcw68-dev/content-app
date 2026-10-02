/**
 * Offline proof of the rate card: no key, no network, nothing spent.
 *
 *   npx tsx scripts/rate-card-check.ts
 *
 * Prints what every house model costs in credits at its default settings and
 * what it earns, and FAILS (exit 1) if any of these is wrong:
 *   - the phone and the server disagree on a price (they round differently, so
 *     the adapter must hand over amounts that are whole credits);
 *   - `CREDIT_USD` in credits.ts and in fal.ts differ;
 *   - a quote is below what fal charges us;
 *   - a price is not a whole number of credits.
 *
 * Netro, 2 Oct 2026: credits shown as ordinary credits with a rate card, not a
 * money-looking number.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describeCatalogue, falAdapter } from "../supabase/functions/_shared/connectors/fal.ts";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (file: string) => fs.readFileSync(path.join(REPO, file), "utf8");

const constant = (file: string) => {
  const found = /const CREDIT_USD = ([0-9.]+);/.exec(read(file));
  if (!found) throw new Error(`no CREDIT_USD in ${file}`);
  return Number(found[1]);
};

const serverUnit = constant("supabase/functions/_shared/credits.ts");
const falUnit = constant("supabase/functions/_shared/connectors/fal.ts");

let failures = 0;
const fail = (message: string) => {
  failures++;
  console.log(`  ✗ ${message}`);
};

if (serverUnit !== falUnit) fail(`CREDIT_USD differs: credits.ts ${serverUnit}, fal.ts ${falUnit}`);

// The server's rounding (credits.ts) and the phone's (GenerateChoices.credits).
const serverCredits = (amount: number) => Math.max(1, Math.round(amount / serverUnit));
const phoneCredits = (amount: number) => Math.max(1, Math.round(amount * 100));

// What an hour of one average sub earns us per credit, from the plans and
// Apple's 15%: the WORST case is Max yearly at full use.
const REVENUE_PER_CREDIT = { worst: 0.0177, blend: 0.02 };

const rows: Array<Record<string, string | number>> = [];
for (const model of describeCatalogue()) {
  const video = model.capability === "video_generation";
  const defaults = ((model.metadata as any)?.constraints?.defaults ?? {}) as Record<string, unknown>;
  const duration = video ? Number(defaults.duration ?? 5) : undefined;
  // Clips are compared at 5s where the model offers it, else its shortest.
  const durations: number[] = (model.metadata as any)?.constraints?.durations ?? [];
  const length = video ? (durations.includes(5) ? 5 : durations[0] ?? duration ?? 5) : undefined;

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

  const credits = serverCredits(quote.amount);
  if (credits !== phoneCredits(quote.amount)) {
    fail(`${model.label}: server says ${credits}, phone says ${phoneCredits(quote.amount)} for ${quote.amount}`);
  }
  if (Math.abs(credits * serverUnit - quote.amount) > 1e-9) {
    fail(`${model.label}: ${quote.amount} is not a whole number of credits`);
  }
  const ours = quote.ours ?? 0;
  if (quote.amount + 1e-9 < ours) fail(`${model.label}: charges ${quote.amount}, below our cost ${ours}`);

  const margin = (revenue: number) => `${Math.round((1 - ours / (credits * revenue)) * 100)}%`;
  rows.push({
    model: model.label,
    kind: video ? `${length}s clip` : "picture",
    "we pay": `$${ours.toFixed(3)}`,
    credits,
    "margin worst": margin(REVENUE_PER_CREDIT.worst),
    "margin typical": margin(REVENUE_PER_CREDIT.blend),
    "Pro (800)": Math.floor(800 / credits),
    "Max (2600)": Math.floor(2600 / credits),
  });
}

console.table(rows);
if (failures > 0) {
  console.log(`${failures} problem(s)`);
  process.exit(1);
}
console.log("rate card OK");
