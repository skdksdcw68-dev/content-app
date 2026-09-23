/**
 * Points App Store Server Notifications V2 (production and sandbox) at our
 * apple-notifications-v2 function, so renewals, expiries and refunds reach us
 * without the app being open.
 *
 *   npx tsx scripts/set-subscription-url.ts
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
const URL = "https://dosszkllkassvyprkhrg.supabase.co/functions/v1/apple-notifications-v2";

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
  if (!response.ok) throw new Error(`${method} ${endpoint} → ${response.status}: ${text.slice(0, 500)}`);
  return text ? JSON.parse(text) : {};
}

const apps = await api("GET", "/v1/apps?filter[bundleId]=Autocast");
const app = apps.data[0];
await api("PATCH", `/v1/apps/${app.id}`, {
  data: {
    type: "apps",
    id: app.id,
    attributes: {
      subscriptionStatusUrl: URL,
      subscriptionStatusUrlVersion: "V2",
      subscriptionStatusUrlForSandbox: URL,
      subscriptionStatusUrlVersionForSandbox: "V2",
    },
  },
});
const check = await api("GET", `/v1/apps/${app.id}?fields[apps]=subscriptionStatusUrl,subscriptionStatusUrlForSandbox`);
console.log(check.data.attributes);
