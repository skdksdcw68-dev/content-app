/**
 * Turns on Sign in with Apple for the Autocast App ID and re-mints the App
 * Store provisioning profile so it carries the entitlement.
 *
 *   npx tsx scripts/enable-apple-signin.ts
 *
 * The certificate is reused (its slot is precious -- see bootstrap-signing.ts);
 * only the profile is replaced, because a profile snapshots the App ID's
 * capabilities at the moment it is created. The new profile is written over
 * ~/Downloads/content-app-secrets/profile.mobileprovision.
 */

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "..");
const BUNDLE_ID = "Autocast";
const PROFILE_NAME = "content-app AppStore";
const OUT_DIR = path.join(os.homedir(), "Downloads", "content-app-secrets");

for (const line of fs.readFileSync(path.join(REPO, ".env"), "utf8").split(/\r?\n/)) {
  const match = /^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
  const [, key, raw] = match ?? [];
  if (key && raw !== undefined && !process.env[key]) process.env[key] = raw.replace(/^["']|["']$/g, "");
}
const { ASC_KEY_ID: keyId, ASC_ISSUER_ID: issuerId, ASC_KEY_PATH: keyPath } = process.env;
if (!keyId || !issuerId || !keyPath) throw new Error("ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH are required");

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
  if (!response.ok) throw new Error(`${method} ${endpoint} → ${response.status}: ${text.slice(0, 400)}`);
  return text ? JSON.parse(text) : {};
}

const bundles = await api("GET", `/v1/bundleIds?filter[identifier]=${BUNDLE_ID}&limit=10`);
const bundle = bundles.data.find((b: any) => b.attributes.identifier === BUNDLE_ID);
if (!bundle) throw new Error("App ID not found");
console.log("App ID", bundle.id);

const capabilities = await api("GET", `/v1/bundleIds/${bundle.id}/bundleIdCapabilities`);
const has = capabilities.data.some((c: any) => c.attributes.capabilityType === "APPLE_ID_AUTH");
if (has) {
  console.log("Sign in with Apple already on");
} else {
  await api("POST", "/v1/bundleIdCapabilities", {
    data: {
      type: "bundleIdCapabilities",
      attributes: {
        capabilityType: "APPLE_ID_AUTH",
        settings: [{ key: "APPLE_ID_AUTH_APP_CONSENT", options: [{ key: "PRIMARY_APP_CONSENT" }] }],
      },
      relationships: { bundleId: { data: { type: "bundleIds", id: bundle.id } } },
    },
  });
  console.log("Sign in with Apple turned on");
}

// The certificate behind the p12 CI signs with.
const der = fs.readFileSync(path.join(OUT_DIR, "cert.der")).toString("base64");
const certificates = await api("GET", "/v1/certificates?limit=200");
const certificate = certificates.data.find((c: any) => c.attributes.certificateContent === der);
if (!certificate) throw new Error("The local certificate is not on the account any more");
console.log("Certificate", certificate.id, certificate.attributes.name);

const profiles = await api("GET", "/v1/profiles?limit=200");
for (const old of profiles.data.filter((p: any) => p.attributes.name === PROFILE_NAME)) {
  await api("DELETE", `/v1/profiles/${old.id}`);
  console.log("Removed old profile", old.id);
}

const created = await api("POST", "/v1/profiles", {
  data: {
    type: "profiles",
    attributes: { name: PROFILE_NAME, profileType: "IOS_APP_STORE" },
    relationships: {
      bundleId: { data: { type: "bundleIds", id: bundle.id } },
      certificates: { data: [{ type: "certificates", id: certificate.id }] },
    },
  },
});
const content = Buffer.from(created.data.attributes.profileContent, "base64");
fs.writeFileSync(path.join(OUT_DIR, "profile.mobileprovision"), content);
const carries = content.toString("latin1").includes("com.apple.developer.applesignin");
console.log("New profile", created.data.id, "written;", carries ? "carries Sign in with Apple ✓" : "MISSING the entitlement ✗");
if (!carries) process.exit(1);
