/** Prints each Autocast Pro plan's US price and intro offer, as Apple has them. */
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
const get = async (p: string): Promise<any> => (await fetch(`https://api.appstoreconnect.apple.com${p}`, { headers: { Authorization: `Bearer ${tok()}` } })).json();
for (const id of ["6813777379", "6813777306"]) {
  const sub = await get(`/v1/subscriptions/${id}`);
  const prices = await get(`/v1/subscriptions/${id}/prices?filter[territory]=USA&include=subscriptionPricePoint&limit=5`);
  const usd = (prices.included ?? []).map((p: any) => p.attributes.customerPrice);
  const offers = await get(`/v1/subscriptions/${id}/introductoryOffers?limit=5`);
  console.log(sub.data.attributes.productId, sub.data.attributes.state, "USD", usd.join(","),
    "offers", (offers.data ?? []).map((o: any) => `${o.attributes.offerMode} ${o.attributes.duration}`).join(", ") || "none");
}
