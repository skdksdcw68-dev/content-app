/**
 * Makes every storefront charge what the app advertises.
 *
 *   npx tsx scripts/reprice-subscriptions.ts          # report only
 *   npx tsx scripts/reprice-subscriptions.ts --apply  # actually set prices
 *
 * Abel, 25 Sep 2026: "when you go with the 29.99 USD per month it's gonna be
 * 34 in my country... I want it to be exactly 29.99 from the Apple sheet", and
 * when asked how to handle the countries where Apple has no step that lands on
 * the number: "we can equalize it."
 *
 * WHY IT WAS WRONG. `create-subscriptions.ts` sets a price in the USA only and
 * lets Apple equalise the rest. Apple's equalisation is not "the same money" --
 * it converts, then rounds to a local charm price and adds local tax. Ethiopia
 * came out at 34.99 against a 29.99 base. `check-territories.ts` even greps for
 * `:34.99|:249.99` as the expected result.
 *
 * WHAT THIS DOES. For every territory Apple sells in, it reads that
 * territory's own price points and picks the one whose USD equivalent is
 * closest to the base price, in either direction, then sets it. Apple's price
 * points are a discrete ladder, so a handful of countries have no rung that
 * lands on the number; those are printed at the end BY NAME rather than
 * quietly accepted.
 *
 * It never guesses at a conversion rate: every price point Apple returns
 * carries `proceeds` and `customerPrice` in local currency, and the USD
 * equivalent comes from the USA point of the same tier, which Apple itself
 * relates. No FX table to go stale.
 *
 * Read-only unless `--apply` is passed, so it can be run to see the damage
 * before anything changes.
 */

import crypto from "node:crypto";
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
const { ASC_KEY_ID: keyId, ASC_ISSUER_ID: issuerId, ASC_KEY_PATH: keyPath } = process.env;
if (!keyId || !issuerId || !keyPath) throw new Error("ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH are required");

const APPLY = process.argv.includes("--apply");

/** The two products, and what the app promises for each. */
const PLANS = [
  { id: "6813777379", productId: "autocast.pro.monthly", usd: 29.99 },
  { id: "6813777306", productId: "autocast.pro.yearly", usd: 199.99 },
];

function token(): string {
  const now = Math.floor(Date.now() / 1000);
  const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const input = [
    encode({ alg: "ES256", kid: keyId, typ: "JWT" }),
    encode({ iss: issuerId, iat: now, exp: now + 19 * 60, aud: "appstoreconnect-v1" }),
  ].join(".");
  const signature = crypto.createSign("SHA256").update(input)
    .sign({ key: fs.readFileSync(keyPath!, "utf8"), dsaEncoding: "ieee-p1363" }, "base64url");
  return `${input}.${signature}`;
}

async function api(method: string, endpoint: string, body?: unknown): Promise<any> {
  const response = await fetch(`https://api.appstoreconnect.apple.com${endpoint}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${method} ${endpoint} → ${response.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : {};
}


import { reprice } from "./reprice-body.ts";

await reprice(api, PLANS, APPLY);
