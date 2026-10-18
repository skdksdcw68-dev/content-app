/** Makes both Autocast Pro plans available in every App Store territory
 *  (and future ones). Prints what was there before. */
import crypto from "node:crypto";
import fs from "node:fs";
for (const line of fs.readFileSync(".env", "utf8").split(/\r?\n/)) {
  const m = /^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
  const [, key, raw] = m ?? [];
  if (key && raw !== undefined && !process.env[key]) process.env[key] = raw.replace(/^["']|["']$/g, "");
}
const { ASC_KEY_ID: kid, ASC_ISSUER_ID: iss, ASC_KEY_PATH: keyPath } = process.env;
const tok = () => {
  const now = Math.floor(Date.now() / 1000);
  const e = (v: object) => Buffer.from(JSON.stringify(v)).toString("base64url");
  const input = `${e({ alg: "ES256", kid, typ: "JWT" })}.${e({ iss, iat: now, exp: now + 900, aud: "appstoreconnect-v1" })}`;
  return `${input}.${crypto.createSign("SHA256").update(input).sign({ key: fs.readFileSync(keyPath!, "utf8"), dsaEncoding: "ieee-p1363" }, "base64url")}`;
};
async function call(method: string, p: string, body?: unknown): Promise<any> {
  for (let i = 0; ; i++) {
    try {
      const r = await fetch(`https://api.appstoreconnect.apple.com${p}`, {
        method, headers: { Authorization: `Bearer ${tok()}`, ...(body ? { "Content-Type": "application/json" } : {}) },
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      const t = await r.text();
      if (!r.ok) throw new Error(`${method} ${p} → ${r.status}: ${t.slice(0, 400)}`);
      return t ? JSON.parse(t) : {};
    } catch (e) { if (i >= 3 || String(e).includes("→ 4")) throw e; await new Promise((r) => setTimeout(r, 3000)); }
  }
}
async function all(p: string): Promise<any[]> {
  const out: any[] = []; let next: string | null = p;
  while (next) { const page = await call("GET", next); out.push(...page.data); next = page.links?.next?.replace("https://api.appstoreconnect.apple.com", "") ?? null; }
  return out;
}
const territories = (await all("/v1/territories?limit=200")).map((t) => t.id);
console.log("App Store territories:", territories.length);
// Every product Autocast sells. Pass ids to do only those: a new subscription
// cannot be priced in ANY territory until it is made available there ("The
// provided territory is not supported for your subscription and planType").
const ALL_PRODUCTS: Array<[string, string]> = [
  ["pro monthly", "6813777379"], ["pro yearly", "6813777306"],
  ["max monthly", "6818623085"], ["max yearly", "6818623325"],
  ["ultra monthly", "6818623354"],
];
const only = process.argv.slice(2);
for (const [name, id] of ALL_PRODUCTS.filter(([, id]) => only.length === 0 || only.includes(id))) {
  let before = "not set";
  try { before = `${(await all(`/v1/subscriptionAvailabilities/${id}/availableTerritories?limit=200`)).length} territories`; } catch { /* none yet */ }
  await call("POST", "/v1/subscriptionAvailabilities", {
    data: {
      type: "subscriptionAvailabilities",
      attributes: { availableInNewTerritories: true },
      relationships: {
        subscription: { data: { type: "subscriptions", id } },
        availableTerritories: { data: territories.map((t) => ({ type: "territories", id: t })) },
      },
    },
  });
  const after = (await all(`/v1/subscriptionAvailabilities/${id}/availableTerritories?limit=200`)).length;
  console.log(name, "before:", before, "→ now:", after, "territories");
}
