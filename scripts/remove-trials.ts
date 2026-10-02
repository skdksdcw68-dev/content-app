/**
 * Removes every free-trial (introductory) offer from Autocast's subscriptions in
 * App Store Connect.
 *
 *   npx tsx scripts/remove-trials.ts            # REPORT ONLY: lists the offers, deletes nothing
 *   npx tsx scripts/remove-trials.ts --apply    # deletes them
 *
 * Netro, 2 Oct 2026: "there is no free trial for any new users ... they only get
 * paid things." `create-subscriptions.ts` once gave Pro yearly a 3-day free
 * trial (Apple's minimum); this takes it off, in every storefront it was put in.
 *
 * Looks at every subscription in the group, not a fixed list, so Max and Ultra
 * are covered the day they exist. Safe to run twice.
 */

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
for (const line of fs.readFileSync(path.join(REPO, ".env"), "utf8").split(/\r?\n/)) {
  const match = /^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
  const [, key, raw] = match ?? [];
  if (key && raw !== undefined && !process.env[key]) process.env[key] = raw.replace(/^["']|["']$/g, "");
}
const { ASC_KEY_ID: keyId, ASC_ISSUER_ID: issuerId, ASC_KEY_PATH: keyPath } = process.env;
if (!keyId || !issuerId || !keyPath) throw new Error("ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH are required");

const APPLY = process.argv.includes("--apply");
const BUNDLE_ID = "Autocast";

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

async function api(method: string, endpoint: string): Promise<any> {
  if (method !== "GET" && !APPLY) throw new Error(`refusing to ${method} ${endpoint} without --apply`);
  for (let attempt = 1; ; attempt++) {
    try {
      const url = endpoint.startsWith("http") ? endpoint : `https://api.appstoreconnect.apple.com${endpoint}`;
      const response = await fetch(url, { method, headers: { Authorization: `Bearer ${token()}` } });
      if (response.status === 204) return null;
      const text = await response.text();
      if (!response.ok) throw new Error(`${method} ${endpoint} -> ${response.status} ${text.slice(0, 200)}`);
      return text ? JSON.parse(text) : null;
    } catch (error) {
      if (attempt >= 4) throw error;
      await new Promise((resolve) => setTimeout(resolve, 1500 * attempt));
    }
  }
}

/** Every page of a list call. */
async function all(endpoint: string): Promise<any[]> {
  const rows: any[] = [];
  let next: string | undefined = endpoint;
  while (next) {
    const page: any = await api("GET", next);
    rows.push(...(page?.data ?? []));
    next = page?.links?.next;
  }
  return rows;
}

const apps = await api("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
const app = apps.data[0];
if (!app) throw new Error(`no app with bundle id ${BUNDLE_ID}`);

const groups = await all(`/v1/apps/${app.id}/subscriptionGroups?limit=50`);
let found = 0;
let removed = 0;
for (const group of groups) {
  const subs = await all(`/v1/subscriptionGroups/${group.id}/subscriptions?limit=50`);
  for (const sub of subs) {
    const offers = await all(`/v1/subscriptions/${sub.id}/introductoryOffers?limit=200`);
    console.log(`${sub.attributes.productId}: ${offers.length} introductory offer(s)`);
    for (const offer of offers) {
      found++;
      const what = `${offer.attributes.offerMode} ${offer.attributes.duration} x${offer.attributes.numberOfPeriods}`;
      if (!APPLY) continue;
      await api("DELETE", `/v1/subscriptionIntroductoryOffers/${offer.id}`);
      removed++;
      console.log(`  removed ${what} (${offer.id})`);
    }
  }
}

console.log(APPLY ? `removed ${removed} of ${found}` : `would remove ${found} (run with --apply)`);
