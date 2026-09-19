/**
 * Creates Autocast Pro in App Store Connect: one subscription group, a monthly
 * and a yearly plan, US prices ($29.99 / $199.99, other storefronts follow
 * Apple's equalisation), and a 3-day free trial on the yearly plan only.
 *
 *   npx tsx scripts/create-subscriptions.ts
 *
 * Safe to run twice: whatever already exists is found and reused.
 */

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
for (const line of fs.readFileSync(path.join(REPO, ".env"), "utf8").split(/\r?\n/)) {
  const match = /^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
  if (match && !process.env[match[1]]) process.env[match[1]] = match[2].replace(/^["']|["']$/g, "");
}
const { ASC_KEY_ID: keyId, ASC_ISSUER_ID: issuerId, ASC_KEY_PATH: keyPath } = process.env;
if (!keyId || !issuerId || !keyPath) throw new Error("ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH are required");

const BUNDLE_ID = "Autocast";
const GROUP = "Autocast Pro";
const PLANS = [
  { productId: "autocast.pro.monthly", name: "Pro Monthly", period: "ONE_MONTH", usd: "29.99", trial: false,
    display: "Autocast Pro", description: "Plans, captions and posting, every month." },
  { productId: "autocast.pro.yearly", name: "Pro Yearly", period: "ONE_YEAR", usd: "199.99", trial: true,
    display: "Autocast Pro Yearly", description: "Everything in Pro for a year, at a lower price." },
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
  for (let attempt = 1; ; attempt++) {
    try {
      const response = await fetch(`https://api.appstoreconnect.apple.com${endpoint}`, {
        method,
        headers: { Authorization: `Bearer ${token()}`, ...(body ? { "Content-Type": "application/json" } : {}) },
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      const text = await response.text();
      if (!response.ok) throw new Error(`${method} ${endpoint} → ${response.status}: ${text.slice(0, 600)}`);
      return text ? JSON.parse(text) : {};
    } catch (error) {
      if (attempt >= 3 || String(error).includes("→ 4")) throw error;
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

const apps = await api("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
const app = apps.data[0];
if (!app) throw new Error("App not found");
console.log("App", app.id, app.attributes.name);

const groups = await api("GET", `/v1/apps/${app.id}/subscriptionGroups?limit=50`);
let group = groups.data.find((g: any) => g.attributes.referenceName === GROUP);
if (!group) {
  group = (await api("POST", "/v1/subscriptionGroups", {
    data: {
      type: "subscriptionGroups",
      attributes: { referenceName: GROUP },
      relationships: { app: { data: { type: "apps", id: app.id } } },
    },
  })).data;
  console.log("Created group", group.id);
} else {
  console.log("Group exists", group.id);
}

// The name people see for the group in Settings → Subscriptions.
const groupLocs = await api("GET", `/v1/subscriptionGroups/${group.id}/subscriptionGroupLocalizations`);
if (!groupLocs.data.some((l: any) => l.attributes.locale === "en-US")) {
  await api("POST", "/v1/subscriptionGroupLocalizations", {
    data: {
      type: "subscriptionGroupLocalizations",
      attributes: { locale: "en-US", name: "Autocast Pro" },
      relationships: { subscriptionGroup: { data: { type: "subscriptionGroups", id: group.id } } },
    },
  });
}

const existing = await api("GET", `/v1/subscriptionGroups/${group.id}/subscriptions?limit=50`);

for (const [index, plan] of PLANS.entries()) {
  let sub = existing.data.find((s: any) => s.attributes.productId === plan.productId);
  if (!sub) {
    sub = (await api("POST", "/v1/subscriptions", {
      data: {
        type: "subscriptions",
        attributes: {
          name: plan.name,
          productId: plan.productId,
          subscriptionPeriod: plan.period,
          familySharable: false,
          reviewNote: "Unlocks full plans, AI captions and unlimited posting. Test with a sandbox account.",
          groupLevel: index + 1,
        },
        relationships: { group: { data: { type: "subscriptionGroups", id: group.id } } },
      },
    })).data;
    console.log("Created", plan.productId, sub.id);
  } else {
    console.log("Exists", plan.productId, sub.id);
  }

  const locs = await api("GET", `/v1/subscriptions/${sub.id}/subscriptionLocalizations`);
  if (!locs.data.some((l: any) => l.attributes.locale === "en-US")) {
    await api("POST", "/v1/subscriptionLocalizations", {
      data: {
        type: "subscriptionLocalizations",
        attributes: { locale: "en-US", name: plan.display, description: plan.description },
        relationships: { subscription: { data: { type: "subscriptions", id: sub.id } } },
      },
    });
  }

  // Price: find the US price point for the amount, then set it; Apple
  // equalises the other storefronts from it.
  const points = await api("GET",
    `/v1/subscriptions/${sub.id}/pricePoints?filter[territory]=USA&limit=800`);
  const point = points.data.find((p: any) => p.attributes.customerPrice === plan.usd);
  if (!point) throw new Error(`No US price point at ${plan.usd}`);
  const prices = await api("GET", `/v1/subscriptions/${sub.id}/prices?limit=5`);
  if (prices.data.length === 0) {
    // Refused until the Paid Apps Agreement is active; everything else still
    // gets created, and running this again later sets the price.
    await api("POST", "/v1/subscriptionPrices", {
      data: {
        type: "subscriptionPrices",
        attributes: { preserveCurrentPrice: false },
        relationships: {
          subscription: { data: { type: "subscriptions", id: sub.id } },
          subscriptionPricePoint: { data: { type: "subscriptionPricePoints", id: point.id } },
        },
      },
    }).then(() => console.log("  priced", plan.usd, "USD"))
      .catch((e) => console.log("  PRICE REFUSED (Paid Apps Agreement?):", String(e).slice(0, 120)));
  } else {
    console.log("  already priced");
  }

  if (plan.trial) {
    const offers = await api("GET", `/v1/subscriptions/${sub.id}/introductoryOffers?limit=5`);
    if (offers.data.length === 0) {
      await api("POST", "/v1/subscriptionIntroductoryOffers", {
        data: {
          type: "subscriptionIntroductoryOffers",
          attributes: { duration: "THREE_DAYS", offerMode: "FREE_TRIAL", numberOfPeriods: 1 },
          relationships: {
            subscription: { data: { type: "subscriptions", id: sub.id } },
            territory: { data: { type: "territories", id: "USA" } },
          },
        },
      }).then(() => console.log("  3-day free trial added (US)"))
        .catch((e) => console.log("  TRIAL REFUSED:", String(e).slice(0, 160)));
    } else {
      console.log("  trial already set");
    }
  }
}
console.log("Done.");
