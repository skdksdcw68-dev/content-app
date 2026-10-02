/**
 * Adds Max and Ultra to Autocast's subscription group in App Store Connect,
 * beside Pro, so people can choose and subscribe.
 *
 *   npx tsx scripts/create-tiers.ts            # REPORT ONLY: reads, prints, changes nothing
 *   npx tsx scripts/create-tiers.ts --apply    # creates what is missing
 *
 * Netro, 29 Sep 2026: "we can split it, pro, max and 1 more so they choose and
 * subscribe." APPROVED by him on 2 Oct 2026: Pro $29.99 / $249.99, Max $79.99 /
 * $649.99, Ultra $199.99 a month and NO Ultra yearly (Apple's US ladder stops
 * near $1,000, and $999.99 for 7,000 credits a month earns about 1% at full
 * use). This still does nothing until it is told to, and every price can be
 * overridden on the command line:
 *
 *   --max-monthly 79.99 --max-yearly 649.99 --ultra-monthly 199.99
 *
 * WHAT IT DOES, in the group `create-subscriptions.ts` made ("Autocast Pro"):
 *   - creates autocast.max.{monthly,yearly} and autocast.ultra.monthly, each
 *     with its English name and description, if they do not exist;
 *   - sets each one's US price to the price point that matches the amount
 *     exactly (other storefronts: run `reprice-subscriptions.ts --apply` after,
 *     with the new ids added to its list);
 *   - ranks the group: level 1 is the HIGHEST service. Ultra 1, Max 2, Pro 3,
 *     with a tier's monthly and yearly products on the same level (a change of
 *     length inside one tier is a crossgrade; moving up a tier is an upgrade and
 *     takes effect at once, prorated; moving down waits for the renewal).
 *
 * WHAT IT DOES NOT DO: touch Pro's price (Pro yearly is $199.99 there today and
 * the approved price is $249.99 -- that is a separate, deliberate step,
 * `--reprice-pro-yearly`), add a free trial (there is none, for anyone: Netro,
 * 2 Oct 2026), or submit anything for review.
 *
 * Safe to run twice: whatever exists is found and reused.
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
const REPRICE_PRO_YEARLY = process.argv.includes("--reprice-pro-yearly");

/** `--name value` from the command line, as a price with two decimals. */
function priced(name: string, fallback: string): string {
  const at = process.argv.indexOf(`--${name}`);
  const said = at >= 0 ? process.argv[at + 1] : undefined;
  return said && /^\d+(\.\d{1,2})?$/.test(said) ? Number(said).toFixed(2) : fallback;
}

const BUNDLE_ID = "Autocast";
const GROUP = "Autocast Pro";

/** Higher tier, lower number: level 1 is the best service. */
const LEVEL = { ultra: 1, max: 2, pro: 3 } as const;

const PLANS = [
  {
    tier: "max", productId: "autocast.max.monthly", name: "Max Monthly", period: "ONE_MONTH",
    usd: priced("max-monthly", "79.99"), trial: false,
    display: "Autocast Max", description: "2,600 credits a month, and every model including Veo 3.1 and Seedance 2.5.",
  },
  {
    tier: "max", productId: "autocast.max.yearly", name: "Max Yearly", period: "ONE_YEAR",
    usd: priced("max-yearly", "649.99"), trial: false,
    display: "Autocast Max Yearly", description: "Everything in Max for a year, at a lower price.",
  },
  {
    tier: "ultra", productId: "autocast.ultra.monthly", name: "Ultra Monthly", period: "ONE_MONTH",
    usd: priced("ultra-monthly", "199.99"), trial: false,
    display: "Autocast Ultra", description: "7,000 credits a month, for a series every day on the best models.",
  },
  // No Ultra yearly: see the header.
] as const;

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
  // Reads are always allowed. Anything that writes needs --apply: a report run
  // that quietly changed something would not be a report.
  if (method !== "GET" && !APPLY) throw new Error(`refusing to ${method} ${endpoint} without --apply`);
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

console.log(APPLY ? "APPLYING" : "REPORT ONLY (nothing will be changed; add --apply to create)");

const apps = await api("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
const app = apps.data[0];
if (!app) throw new Error("App not found");
console.log("App", app.id, app.attributes.name);

const groups = await api("GET", `/v1/apps/${app.id}/subscriptionGroups?limit=50`);
const group = groups.data.find((g: any) => g.attributes.referenceName === GROUP);
if (!group) throw new Error(`Subscription group "${GROUP}" not found -- run create-subscriptions.ts first`);
console.log("Group", group.id);

const existing = await api("GET", `/v1/subscriptionGroups/${group.id}/subscriptions?limit=50`);
console.log("\nToday in the group:");
for (const s of existing.data) {
  const a = s.attributes;
  console.log(`  ${String(a.productId).padEnd(26)} level ${a.groupLevel}  ${a.subscriptionPeriod}  state ${a.state}`);
}

// ------------------------------------------------------------ Pro's own level

console.log("\nLevels (1 is the highest service):");
for (const s of existing.data) {
  const tier = String(s.attributes.productId).split(".")[1] as keyof typeof LEVEL;
  const want = LEVEL[tier];
  if (!want || s.attributes.groupLevel === want) continue;
  console.log(`  ${s.attributes.productId}: level ${s.attributes.groupLevel} -> ${want}`);
  if (APPLY) {
    await api("PATCH", `/v1/subscriptions/${s.id}`, {
      data: { type: "subscriptions", id: s.id, attributes: { groupLevel: want } },
    }).catch((e) => console.log("    LEVEL REFUSED:", String(e).slice(0, 200)));
  }
}

// ------------------------------------------------------------ the new plans

for (const plan of PLANS) {
  console.log(`\n${plan.productId}  $${plan.usd}  ${plan.period}`);

  // What exists at that price. Read-only, so the report says whether the
  // number can be charged at all -- Apple's ladder of price points is not
  // continuous, and the top of it is not guaranteed to hold $1,599.99.
  const probe = existing.data.find((s: any) => s.attributes.productId === plan.productId)
    ?? existing.data[0];
  const points = await api("GET",
    `/v1/subscriptions/${probe.id}/pricePoints?filter[territory]=USA&limit=8000`);
  const exact = points.data.find((p: any) => p.attributes.customerPrice === plan.usd);
  if (exact) {
    console.log("  US price point exists at exactly", plan.usd);
  } else {
    const wanted = Number(plan.usd);
    const nearest = points.data
      .map((p: any) => Number(p.attributes.customerPrice))
      .filter((n: number) => Number.isFinite(n))
      .sort((a: number, b: number) => Math.abs(a - wanted) - Math.abs(b - wanted))
      .slice(0, 4);
    console.log(`  NO US price point at ${plan.usd}. Nearest: ${nearest.join(", ")}. Choose one of these.`);
  }

  let sub = existing.data.find((s: any) => s.attributes.productId === plan.productId);
  if (!sub) {
    console.log("  would create the subscription");
    if (!APPLY) continue;
    sub = (await api("POST", "/v1/subscriptions", {
      data: {
        type: "subscriptions",
        attributes: {
          name: plan.name,
          productId: plan.productId,
          subscriptionPeriod: plan.period,
          familySharable: false,
          reviewNote: "Unlocks a monthly allowance of credits for making video and pictures, and more of the models. Test with a sandbox account.",
          groupLevel: LEVEL[plan.tier],
        },
        relationships: { group: { data: { type: "subscriptionGroups", id: group.id } } },
      },
    })).data;
    console.log("  created", sub.id);
  } else {
    console.log("  exists", sub.id);
  }

  const locs = await api("GET", `/v1/subscriptions/${sub.id}/subscriptionLocalizations`);
  if (!locs.data.some((l: any) => l.attributes.locale === "en-US")) {
    console.log("  would add the English name and description");
    if (APPLY) {
      await api("POST", "/v1/subscriptionLocalizations", {
        data: {
          type: "subscriptionLocalizations",
          attributes: { locale: "en-US", name: plan.display, description: plan.description },
          relationships: { subscription: { data: { type: "subscriptions", id: sub.id } } },
        },
      });
    }
  }

  if (!exact) continue;
  const prices = await api("GET", `/v1/subscriptions/${sub.id}/prices?limit=5`);
  if (prices.data.length === 0) {
    console.log("  would set the US price to", plan.usd);
    if (APPLY) {
      await api("POST", "/v1/subscriptionPrices", {
        data: {
          type: "subscriptionPrices",
          attributes: { preserveCurrentPrice: false },
          relationships: {
            subscription: { data: { type: "subscriptions", id: sub.id } },
            subscriptionPricePoint: { data: { type: "subscriptionPricePoints", id: exact.id } },
          },
        },
      }).then(() => console.log("  priced", plan.usd, "USD"))
        .catch((e) => console.log("  PRICE REFUSED (Paid Apps Agreement?):", String(e).slice(0, 160)));
    }
  } else {
    console.log("  already priced");
  }

  if (plan.trial) {
    const offers = await api("GET", `/v1/subscriptions/${sub.id}/introductoryOffers?limit=5`);
    if (offers.data.length === 0) {
      console.log("  would add the 3-day free trial (US)");
      if (APPLY) {
        await api("POST", "/v1/subscriptionIntroductoryOffers", {
          data: {
            type: "subscriptionIntroductoryOffers",
            attributes: { duration: "THREE_DAYS", offerMode: "FREE_TRIAL", numberOfPeriods: 1 },
            relationships: {
              subscription: { data: { type: "subscriptions", id: sub.id } },
              territory: { data: { type: "territories", id: "USA" } },
            },
          },
        }).catch((e) => console.log("  TRIAL REFUSED:", String(e).slice(0, 160)));
      }
    }
  }
}

// ----------------------------------------------- Pro yearly, if asked to

if (REPRICE_PRO_YEARLY) {
  const proYearly = existing.data.find((s: any) => s.attributes.productId === "autocast.pro.yearly");
  const target = priced("pro-yearly", "249.99");
  console.log(`\nPro yearly -> $${target}`);
  if (proYearly) {
    const points = await api("GET", `/v1/subscriptions/${proYearly.id}/pricePoints?filter[territory]=USA&limit=8000`);
    const point = points.data.find((p: any) => p.attributes.customerPrice === target);
    if (!point) console.log("  NO price point at", target);
    else if (APPLY) {
      await api("POST", "/v1/subscriptionPrices", {
        data: {
          type: "subscriptionPrices",
          attributes: { preserveCurrentPrice: false },
          relationships: {
            subscription: { data: { type: "subscriptions", id: proYearly.id } },
            subscriptionPricePoint: { data: { type: "subscriptionPricePoints", id: point.id } },
          },
        },
      }).then(() => console.log("  priced"))
        .catch((e) => console.log("  REFUSED:", String(e).slice(0, 200)));
    } else {
      console.log("  would set it (no paying customer is on the old price yet; only sandbox testers)");
    }
  }
}

console.log(APPLY ? "\nDone." : "\nReport finished. Nothing was changed.");
