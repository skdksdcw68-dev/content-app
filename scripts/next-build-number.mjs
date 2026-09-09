/**
 * The next build number, asked of App Store Connect directly.
 *
 * fastlane's `latest_testflight_build_number` was tried twice here and failed
 * silently both times -- first because it was filtered by a version read off
 * the target (MARKETING_VERSION is declared at project level, so it raised),
 * then unfiltered, where it still came back with nothing. Each time the rescue
 * swallowed it and the lane fell back to the CI counter, which is exactly the
 * thing that cannot be trusted: a fresh Codemagic account restarts that counter
 * at 1, so builds went up numbered 3, 4 and 5 while 29 already existed.
 *
 * Rather than guess at the helper a third time, this asks the API directly --
 * the same call that has been answering correctly from a laptop all morning.
 * It prints one integer and nothing else, so a CI step can read it.
 *
 * Deliberately unfiltered by version. What matters is the highest number ever
 * used for this app, because the only requirement is that the counter moves
 * forwards; per-version uniqueness is satisfied for free by exceeding
 * everything.
 *
 * Reads the same variables the signing group already provides, so there is
 * nothing new to configure:
 *   APP_STORE_CONNECT_API_KEY_ID
 *   APP_STORE_CONNECT_API_ISSUER_ID
 *   APP_STORE_CONNECT_API_KEY_CONTENT   (base64 of the .p8)
 */

import crypto from "node:crypto";

const KEY_ID = process.env.APP_STORE_CONNECT_API_KEY_ID;
const ISSUER = process.env.APP_STORE_CONNECT_API_ISSUER_ID;
const KEY_B64 = process.env.APP_STORE_CONNECT_API_KEY_CONTENT;
const BUNDLE_ID = process.env.BUNDLE_ID ?? "Autocast";

if (!KEY_ID || !ISSUER || !KEY_B64) {
  console.error("next-build-number: missing App Store Connect credentials");
  process.exit(1);
}

const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

function token() {
  const now = Math.floor(Date.now() / 1000);
  const input = [
    encode({ alg: "ES256", kid: KEY_ID, typ: "JWT" }),
    // Apple rejects anything over twenty minutes.
    encode({ iss: ISSUER, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }),
  ].join(".");

  // JOSE wants raw r||s; Node's default DER encoding is rejected.
  const signature = crypto
    .createSign("SHA256")
    .update(input)
    .sign({ key: Buffer.from(KEY_B64, "base64").toString("utf8"), dsaEncoding: "ieee-p1363" }, "base64url");

  return `${input}.${signature}`;
}

async function api(path) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    headers: { Authorization: `Bearer ${token()}` },
  });
  if (!response.ok) {
    throw new Error(`${path} -> ${response.status} ${(await response.text()).slice(0, 200)}`);
  }
  return response.json();
}

// Looked up rather than hardcoded, so this keeps working if the app record is
// ever recreated.
const apps = await api(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}&limit=1`);
const app = apps.data?.[0];
if (!app) throw new Error(`no app with bundle id ${BUNDLE_ID}`);

// 200 is far more than this app will ever have, and one page keeps it to a
// single request. Sorted newest first so the cap cannot hide a high number
// behind a long tail of old ones.
const builds = await api(`/v1/builds?filter[app]=${app.id}&limit=200&sort=-uploadedDate`);

const highest = (builds.data ?? [])
  .map((build) => Number.parseInt(build.attributes?.version ?? "0", 10))
  .filter((n) => Number.isFinite(n))
  .reduce((max, n) => (n > max ? n : max), 0);

// stdout is the answer and nothing else; anything explanatory goes to stderr so
// a CI step can capture this with a plain command substitution.
console.error(`next-build-number: highest seen ${highest}, using ${highest + 1}`);
console.log(String(highest + 1));
