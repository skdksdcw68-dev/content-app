/**
 * Autocast's own generator: which connection everyone generates through.
 *
 *   npx tsx scripts/house-generator.ts                 # what is true now
 *   npx tsx scripts/house-generator.ts --set <id>      # make that one the house
 *   npx tsx scripts/house-generator.ts --clear         # back to connect-your-own
 *
 * Abel, 25 Sep 2026: "i guess its better to choose something like our own
 * model instead of a connector."
 *
 * 🔴 `--set` STARTS SPENDING REAL MONEY. From that moment every signed-in
 * person who has not connected their own generator runs on this account,
 * metered against `plans_catalog.monthly_video_gens` (free 0, creator 60,
 * studio 250). The metering is in `_shared/generate.ts` and is what makes this
 * safe; read it before running this.
 *
 * A person's own connection always wins, so nobody who connected their own
 * Higgsfield is touched by this or counted against our caps.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "..");

for (const line of fs.readFileSync(path.join(REPO, ".env"), "utf8").split(/\r?\n/)) {
  const match = /^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
  const [, key, raw] = match ?? [];
  if (key && raw !== undefined && !process.env[key]) process.env[key] = raw.replace(/^["']|["']$/g, "");
}

const URL_ = process.env.SUPABASE_URL!;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
if (!URL_ || !KEY) throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required");

const headers = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };

async function rest(pathAndQuery: string): Promise<any> {
  const response = await fetch(`${URL_}/rest/v1/${pathAndQuery}`, { headers });
  const text = await response.text();
  if (!response.ok) throw new Error(`${response.status}: ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

async function rpc(name: string, body: Record<string, unknown>): Promise<any> {
  const response = await fetch(`${URL_}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${name} → ${response.status}: ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

const setIndex = process.argv.indexOf("--set");
const target = setIndex >= 0 ? process.argv[setIndex + 1] : null;
const clearing = process.argv.includes("--clear");

if (setIndex >= 0 && !target) throw new Error("--set needs a connection id");

if (target) {
  await rpc("set_house_connection", { p_connection: target, p_is_house: true });
  console.log(`Set ${target} as the house generator.`);
} else if (clearing) {
  const current = await rest("connections?select=id&is_house=eq.true");
  for (const row of current) {
    await rpc("set_house_connection", { p_connection: row.id, p_is_house: false });
    console.log(`Cleared ${row.id}.`);
  }
  if (current.length === 0) console.log("Nothing was set.");
}

// ------------------------------------------------------------------ report

const connections = await rest(
  "connections?select=id,user_id,status,account_label,is_house,discovered_at&status=eq.active&order=discovered_at.desc",
);

const models = await rest("connection_models?select=connection_id,capability,available");
const counts = new Map<string, Record<string, number>>();
for (const model of models) {
  if (!model.available) continue;
  const bucket = counts.get(model.connection_id) ?? {};
  bucket[model.capability] = (bucket[model.capability] ?? 0) + 1;
  counts.set(model.connection_id, bucket);
}

console.log("\nActive connections:\n");
for (const row of connections) {
  const has = counts.get(row.id) ?? {};
  const video = has.video_generation ?? 0;
  const image = has.image_generation ?? 0;
  console.log(
    `${row.is_house ? "★ HOUSE " : "        "}${row.id}  ` +
      `${String(row.account_label || "(no label)").padEnd(16)} ` +
      `video ${String(video).padStart(3)}  image ${String(image).padStart(3)}  ` +
      `user ${String(row.user_id).slice(0, 8)}`,
  );
}

const house = connections.find((row: any) => row.is_house);
if (!house) {
  console.log("\nNo house generator. Everyone must connect their own, which is");
  console.log("what has stopped every video this account has ever tried to make.");
  console.log("Pick one above with plenty of video models and run:");
  console.log("  npx tsx scripts/house-generator.ts --set <id>");
} else {
  const video = (counts.get(house.id) ?? {}).video_generation ?? 0;
  console.log(`\nHouse generator: ${house.account_label || house.id}, ${video} video models.`);
  console.log("Everyone without their own connection generates through it, capped by");
  console.log("plans_catalog.monthly_video_gens.");
}

// What the caps actually are, since that is what stands between this and a
// bill nobody chose.
const plans = await rest("plans_catalog?select=code,monthly_video_gens,monthly_image_gens&order=monthly_video_gens.asc");
console.log("\nPer person, per month:");
for (const plan of plans) {
  console.log(`  ${String(plan.code).padEnd(8)} ${String(plan.monthly_video_gens).padStart(4)} videos  ${String(plan.monthly_image_gens).padStart(4)} images`);
}
