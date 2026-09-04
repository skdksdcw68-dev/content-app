#!/usr/bin/env node
// Bootstraps this app's signing identity against the App Store Connect API,
// from Windows, with no Mac and no Xcode.
//
// It runs in three escalating modes, because one of the steps is irreversible
// in practice:
//
//   node scripts/bootstrap-signing.mjs                 audit only. No writes.
//   node scripts/bootstrap-signing.mjs --create        mint certificate + profile
//   node scripts/bootstrap-signing.mjs --create --secrets   ... and push to GitHub
//
// Audit is the default on purpose. Apple caps iOS Distribution certificates at
// 2 per account and email-app holds one, so --create spends the LAST slot on
// this team. Run the audit first and read what it says about the quota.
//
// Credentials, from the environment or a .env file beside this script:
//   ASC_KEY_ID      the 10-character key id, e.g. 8LCFS8XL27
//   ASC_ISSUER_ID   the issuer UUID, from App Store Connect ->
//                   Users and Access -> Integrations -> App Store Connect API
//   ASC_KEY_PATH    path to the AuthKey_XXXXXXXXXX.p8
//
// Nothing secret is ever printed, and nothing is written into the repo --
// generated key material goes to OUT_DIR, which is gitignored.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "..");

// Must match project.yml PRODUCT_BUNDLE_IDENTIFIER, fastlane/Fastfile
// BUNDLE_ID and fastlane/Appfile app_identifier.
const BUNDLE_ID = "Autocast";
// Must match PROFILE in fastlane/Fastfile.
const PROFILE_NAME = "content-app AppStore";
const REPO_SLUG = "skdksdcw68-dev/content-app";
const TEAM_ID = "TDMFXRJYN7";

// The legacy type, deliberately. Apple caps Apple Distribution (DISTRIBUTION)
// at 2 per account and both slots are held by drobe and remi; IOS_DISTRIBUTION
// has a separate quota. This is also why fastlane/Fastfile signs with
// "iPhone Distribution" rather than "Apple Distribution".
const CERT_TYPE = "IOS_DISTRIBUTION";
const CERT_QUOTA = 2;

// Key material lands outside the repo entirely, next to the other apps'
// secrets, so a stray `git add -A` can never stage a private key.
const OUT_DIR = path.join(os.homedir(), "Downloads", "content-app-secrets");

const args = new Set(process.argv.slice(2));
const DO_CREATE = args.has("--create");
const DO_SECRETS = args.has("--secrets");

// ---------------------------------------------------------------- utilities

const c = {
  dim: (s) => `\x1b[2m${s}\x1b[0m`,
  bold: (s) => `\x1b[1m${s}\x1b[0m`,
  green: (s) => `\x1b[32m${s}\x1b[0m`,
  yellow: (s) => `\x1b[33m${s}\x1b[0m`,
  red: (s) => `\x1b[31m${s}\x1b[0m`,
};

const ok = (m) => console.log(`${c.green("OK")}   ${m}`);
const info = (m) => console.log(`${c.dim("--")}   ${m}`);
const warn = (m) => console.log(`${c.yellow("WARN")} ${m}`);
function die(m, hint) {
  console.error(`\n${c.red("FAIL")} ${m}`);
  if (hint) console.error(`     ${c.dim(hint)}`);
  process.exit(1);
}

function loadEnv() {
  const envFile = path.join(REPO, ".env");
  if (fs.existsSync(envFile)) {
    for (const line of fs.readFileSync(envFile, "utf8").split("\n")) {
      const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
      if (m && !process.env[m[1]]) {
        process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
      }
    }
  }
  const keyId = process.env.ASC_KEY_ID;
  const issuerId = process.env.ASC_ISSUER_ID;
  const keyPath = process.env.ASC_KEY_PATH;

  const missing = [
    ["ASC_KEY_ID", keyId],
    ["ASC_ISSUER_ID", issuerId],
    ["ASC_KEY_PATH", keyPath],
  ].filter(([, v]) => !v).map(([k]) => k);

  if (missing.length) {
    die(
      `missing ${missing.join(", ")}`,
      "Set them in the environment or in a .env at the repo root (.env is gitignored)."
    );
  }
  if (!fs.existsSync(keyPath)) die(`no .p8 at ${keyPath}`);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(issuerId)) {
    die(
      "ASC_ISSUER_ID is not a UUID",
      "It is the Issuer ID above the key list, not the key id itself."
    );
  }
  return { keyId, issuerId, keyPath };
}

/// ES256 JWT. Apple rejects anything over 20 minutes, and rejects the DER
/// signature encoding Node produces by default -- JOSE wants raw r||s, which
/// is what dsaEncoding "ieee-p1363" gives.
function makeToken({ keyId, issuerId, keyPath }) {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const payload = {
    iss: issuerId,
    iat: now,
    exp: now + 19 * 60,
    aud: "appstoreconnect-v1",
  };
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const signingInput = `${b64(header)}.${b64(payload)}`;

  const signature = crypto
    .createSign("SHA256")
    .update(signingInput)
    .sign(
      { key: fs.readFileSync(keyPath, "utf8"), dsaEncoding: "ieee-p1363" },
      "base64url"
    );

  return `${signingInput}.${signature}`;
}

async function api(token, method, endpoint, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${endpoint}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });

  if (res.status === 204) return null;
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    die(`${method} ${endpoint} returned non-JSON (HTTP ${res.status})`, text.slice(0, 200));
  }
  if (!res.ok) {
    const detail = json.errors?.map((e) => `${e.title}: ${e.detail}`).join("; ") ?? text;
    if (res.status === 401) {
      die(
        `authentication rejected (HTTP 401)`,
        "Check ASC_KEY_ID matches the .p8 filename, and that the key has not been revoked."
      );
    }
    die(`${method} ${endpoint} failed (HTTP ${res.status})`, detail);
  }
  return json;
}

function sh(cmd, cmdArgs, opts = {}) {
  return execFileSync(cmd, cmdArgs, { encoding: "utf8", ...opts });
}

// -------------------------------------------------------------------- audit

async function audit(token) {
  console.log(c.bold("\nAudit\n"));

  // 1. Certificate quota. This is the constraint that decides whether this app
  //    can be signed at all, so it is checked first and loudly.
  const certs = await api(
    token,
    "GET",
    `/v1/certificates?filter[certificateType]=${CERT_TYPE}&limit=200`
  );
  const live = certs.data.filter((d) => {
    const exp = d.attributes.expirationDate;
    return !exp || new Date(exp) > new Date();
  });

  info(`${CERT_TYPE} certificates in use: ${live.length} of ${CERT_QUOTA}`);
  for (const cert of live) {
    const a = cert.attributes;
    info(
      `    ${a.name} ${c.dim(`(${a.serialNumber ?? cert.id}, expires ${a.expirationDate?.slice(0, 10) ?? "?"})`)}`
    );
  }
  const slots = CERT_QUOTA - live.length;
  if (slots <= 0) {
    warn(
      `no ${CERT_TYPE} slots left. A new certificate needs one revoked first -- ` +
        `and revoking one breaks whichever app is signing with it.`
    );
  } else {
    ok(`${slots} slot${slots === 1 ? "" : "s"} free${slots === 1 ? " -- this app takes the last one" : ""}`);
  }

  // 2. The App ID has to exist before a profile can reference it.
  const bundles = await api(
    token,
    "GET",
    `/v1/bundleIds?filter[identifier]=${encodeURIComponent(BUNDLE_ID)}&limit=10`
  );
  const bundle = bundles.data.find((b) => b.attributes.identifier === BUNDLE_ID);
  if (!bundle) {
    die(
      `no App ID registered with identifier "${BUNDLE_ID}"`,
      "Register it on the Developer Portal, or change BUNDLE_ID at the top of this script."
    );
  }
  ok(`App ID "${BUNDLE_ID}" exists ${c.dim(`(${bundle.attributes.name}, ${bundle.id})`)}`);

  // 3. Push. project.yml declares aps-environment, and a profile minted before
  //    the capability is enabled cannot sign a build that declares it --
  //    email-app lost a build to exactly this.
  const caps = await api(
    token,
    "GET",
    `/v1/bundleIds/${bundle.id}/bundleIdCapabilities?limit=200`
  );
  const enabled = caps.data.map((d) => d.attributes.capabilityType);
  const declaresPush = fs
    .readFileSync(path.join(REPO, "project.yml"), "utf8")
    .includes("CODE_SIGN_ENTITLEMENTS");

  if (declaresPush && !enabled.includes("PUSH_NOTIFICATIONS")) {
    warn(
      "the app declares aps-environment but PUSH_NOTIFICATIONS is not enabled on the App ID.\n" +
        "     Tick it in the App ID's Capabilities tab BEFORE minting a profile, or the\n" +
        "     profile will be unable to sign the build. Alternatively drop the entitlement\n" +
        "     (see README, Signing step 1)."
    );
  } else if (declaresPush) {
    ok("PUSH_NOTIFICATIONS enabled, matching the aps-environment entitlement");
  }
  if (enabled.length) info(`capabilities: ${enabled.join(", ")}`);

  // 4. An existing profile of the right name is reused rather than duplicated.
  const profiles = await api(token, "GET", `/v1/profiles?limit=200`);
  const profile = profiles.data.find((p) => p.attributes.name === PROFILE_NAME);
  if (profile) {
    const a = profile.attributes;
    const stale = a.profileState !== "ACTIVE";
    (stale ? warn : ok)(
      `profile "${PROFILE_NAME}" exists ${c.dim(`(${a.profileType}, ${a.profileState}, expires ${a.expirationDate?.slice(0, 10)})`)}`
    );
  } else {
    info(`no profile named "${PROFILE_NAME}" yet`);
  }

  return { bundle, profile, slots };
}

// ------------------------------------------------------------------- create

async function create(token, { bundle, profile, slots }) {
  console.log(c.bold("\nCreate\n"));
  fs.mkdirSync(OUT_DIR, { recursive: true });

  if (slots <= 0) die("refusing to mint: no certificate slots free (see audit above)");

  const keyPem = path.join(OUT_DIR, "signing-key.pem");
  const csrPath = path.join(OUT_DIR, "signing.csr");
  const p12Path = path.join(OUT_DIR, "identity.p12");
  const p12Password = crypto.randomBytes(18).toString("base64url");

  // Apple wants a 2048-bit RSA CSR. MSYS_NO_PATHCONV stops Git Bash rewriting
  // the -subj value into a Windows path, which silently mangles the subject.
  sh("openssl", ["genrsa", "-out", keyPem, "2048"], { stdio: "ignore" });
  sh(
    "openssl",
    ["req", "-new", "-key", keyPem, "-out", csrPath,
     "-subj", "/CN=Autocast Distribution/O=Abel Amare/C=US"],
    { stdio: "ignore", env: { ...process.env, MSYS_NO_PATHCONV: "1" } }
  );
  ok("generated private key and CSR");

  const certRes = await api(token, "POST", "/v1/certificates", {
    data: {
      type: "certificates",
      attributes: {
        certificateType: CERT_TYPE,
        csrContent: fs.readFileSync(csrPath, "utf8"),
      },
    },
  });
  const certId = certRes.data.id;
  ok(`minted certificate ${c.dim(certRes.data.attributes.name ?? certId)}`);

  // The API returns the DER certificate inline, base64'd.
  const derPath = path.join(OUT_DIR, "cert.der");
  const pemPath = path.join(OUT_DIR, "cert.pem");
  fs.writeFileSync(derPath, Buffer.from(certRes.data.attributes.certificateContent, "base64"));
  sh("openssl", ["x509", "-inform", "DER", "-in", derPath, "-out", pemPath], { stdio: "ignore" });

  // -legacy is REQUIRED. OpenSSL 3 defaults to AES-256 + SHA-256 for PKCS#12,
  // which macOS `security` cannot import; it fails with "MAC verification
  // failed during PKCS12 import (wrong password?)", blaming the password.
  sh(
    "openssl",
    ["pkcs12", "-export", "-legacy", "-inkey", keyPem, "-in", pemPath,
     "-out", p12Path, "-passout", `pass:${p12Password}`],
    { stdio: "ignore" }
  );
  ok(`built identity.p12 ${c.dim("(-legacy, so macOS can import it)")}`);

  let profileId = profile?.id;
  if (profile) {
    info(`reusing existing profile "${PROFILE_NAME}"`);
  } else {
    const profRes = await api(token, "POST", "/v1/profiles", {
      data: {
        type: "profiles",
        attributes: { name: PROFILE_NAME, profileType: "IOS_APP_STORE" },
        relationships: {
          bundleId: { data: { type: "bundleIds", id: bundle.id } },
          certificates: { data: [{ type: "certificates", id: certId }] },
        },
      },
    });
    profileId = profRes.data.id;
    ok(`created profile "${PROFILE_NAME}"`);
  }

  const prof = await api(token, "GET", `/v1/profiles/${profileId}`);
  const profilePath = path.join(OUT_DIR, "profile.mobileprovision");
  fs.writeFileSync(profilePath, Buffer.from(prof.data.attributes.profileContent, "base64"));
  ok(`downloaded profile`);

  const notePath = path.join(OUT_DIR, "p12-password.txt");
  fs.writeFileSync(notePath, `P12_PASSWORD=${p12Password}\n`);
  info(`key material in ${OUT_DIR} ${c.dim("(outside the repo)")}`);

  return { p12Path, profilePath, p12Password };
}

// ------------------------------------------------------------------ secrets

function pushSecrets({ p12Path, profilePath, p12Password }, { keyId, issuerId, keyPath }) {
  console.log(c.bold("\nSecrets\n"));

  const set = (name, value) => {
    sh("gh", ["secret", "set", name, "-R", REPO_SLUG], { input: value, stdio: ["pipe", "ignore", "inherit"] });
    ok(`set ${name}`);
  };

  set("APPLE_TEAM_ID", TEAM_ID);
  set("APP_STORE_CONNECT_API_KEY_ID", keyId);
  set("APP_STORE_CONNECT_API_ISSUER_ID", issuerId);
  // is_key_content_base64 is true in the Fastfile, so this must be base64.
  set("APP_STORE_CONNECT_API_KEY_CONTENT", fs.readFileSync(keyPath).toString("base64"));
  // CI-local only: it just unlocks the throwaway keychain the runner creates.
  set("KEYCHAIN_PASSWORD", crypto.randomBytes(18).toString("base64url"));
  set("BUILD_CERTIFICATE_BASE64", fs.readFileSync(p12Path).toString("base64"));
  set("P12_PASSWORD", p12Password);
  set("PROVISIONING_PROFILE_BASE64", fs.readFileSync(profilePath).toString("base64"));
}

// --------------------------------------------------------------------- main

const creds = loadEnv();
const token = makeToken(creds);

const state = await audit(token);

if (!DO_CREATE) {
  console.log(
    `\n${c.dim("Audit only. Re-run with --create to mint the certificate and profile,")}` +
      `\n${c.dim("or --create --secrets to also push all 7 secrets to " + REPO_SLUG + ".")}\n`
  );
  process.exit(0);
}

const built = await create(token, state);
if (DO_SECRETS) pushSecrets(built, creds);

console.log(
  `\n${c.green("Done.")} Next: ${c.bold(`gh workflow run ios-testflight.yml -R ${REPO_SLUG}`)}\n`
);
