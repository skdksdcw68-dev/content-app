/** How many storefronts each plan is priced in, and a sample of prices. */
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
const get = async (p: string): Promise<any> =>
  (await fetch(`https://api.appstoreconnect.apple.com${p}`, { headers: { Authorization: `Bearer ${tok()}` } })).json();
for (const id of ["6813777379", "6813777306"]) {
  const prices = await get(`/v1/subscriptions/${id}/prices?include=subscriptionPricePoint,territory&limit=200`);
  const points = new Map((prices.included ?? []).filter((i: any) => i.type === "subscriptionPricePoints").map((p: any) => [p.id, p.attributes.customerPrice]));
  const rows = (prices.data ?? []).map((p: any) => `${p.relationships.territory.data.id}:${points.get(p.relationships.subscriptionPricePoint.data.id)}`);
  const locs = await get(`/v1/subscriptions/${id}/subscriptionLocalizations`);
  const avail = await get(`/v1/subscriptions/${id}/subscriptionAvailability?include=availableTerritories&limit[availableTerritories]=50`);
  console.log(id, "priced in", rows.length, "e.g.", rows.filter((r: string) => /:34.99|:249.99|ETH/.test(r)).join(" "),
    "| locales", (locs.data ?? []).map((l: any) => l.attributes.locale).join(","),
    "| availability", avail.data ? `${(avail.data.relationships?.availableTerritories?.data ?? []).length} territories` : JSON.stringify(avail.errors?.[0]?.detail ?? "none"));
}
