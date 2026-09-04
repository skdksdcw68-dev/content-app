#!/usr/bin/env -S npx tsx
// Bootstraps this app's signing identity against the App Store Connect API,
// from Windows, with no Mac and no Xcode.
//
// It runs in three escalating modes, because one of the steps is irreversible
// in practice:
//
//   npm run signing:audit     audit only. No writes.
//   npm run signing:create    mint certificate + profile
//   npm run signing:all       ... and push all 7 secrets to GitHub
//
// Audit is the default on purpose. Apple caps iOS Distribution certificates at
// 2 per account and email-app holds one, so --create spends the LAST slot on
// this team. Run the audit first and read what it says about the quota.
//
// Credentials, from the environment or a .env file at the repo root:
//   ASC_KEY_ID      the 10-character key id, e.g. 8LCFS8XL27
//   ASC_ISSUER_ID   the issuer UUID, from App Store Connect ->
//                   Users and Access -> Integrations -> App Store Connect API
//   ASC_KEY_PATH    path to the AuthKey_XXXXXXXXXX.p8
//
// Nothing secret is ever printed, and nothing is written into the repo --
// generated key material goes to OUT_DIR, which is outside it entirely.

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

// ------------------------------------------------------------------- types

interface Credentials {
  readonly keyId: string;
  readonly issuerId: string;
  readonly keyPath: string;
}

/** Only the fields this script actually reads. The API returns far more. */
interface CertificateAttributes {
  name?: string;
  serialNumber?: string;
  certificateType?: string;
  expirationDate?: string;
  certificateContent?: string;
}

interface BundleIdAttributes {
  identifier?: string;
  name?: string;
}

interface ProfileAttributes {
  name?: string;
  profileType?: string;
  profileState?: string;
  expirationDate?: string;
  profileContent?: string;
}

interface CapabilityAttributes {
  capabilityType?: string;
}

interface Resource<A> {
  id: string;
  type: string;
  attributes: A;
}

interface ListResponse<A> {
  data: Resource<A>[];
}

interface SingleResponse<A> {
  data: Resource<A>;
}

interface ApiError {
  title?: string;
  detail?: string;
}

type Certificate = Resource<CertificateAttributes>;
type BundleId = Resource<BundleIdAttributes>;
type Profile = Resource<ProfileAttributes>;

interface AuditResult {
  readonly bundle: BundleId;
  readonly profile: Profile | undefined;
  readonly slots: number;
}

interface BuiltIdentity {
  readonly p12Path: string;
  readonly profilePath: string;
  readonly p12Password: string;
}

// --------------------------------------------------------------- utilities

const c = {
  dim: (s: string): string => `\x1b[2m${s}\x1b[0m`,
  bold: (s: string): string => `\x1b[1m${s}\x1b[0m`,
  green: (s: string): string => `\x1b[32m${s}\x1b[0m`,
  yellow: (s: string): string => `\x1b[33m${s}\x1b[0m`,
  red: (s: string): string => `\x1b[31m${s}\x1b[0m`,
} as const;

const ok = (m: string): void => console.log(`${c.green("OK")}   ${m}`);
const info = (m: string): void => console.log(`${c.dim("--")}   ${m}`);
const warn = (m: string): void => console.log(`${c.yellow("WARN")} ${m}`);

/** Never returns. The `never` return type lets callers use it as an expression. */
function die(message: string, hint?: string): never {
  console.error(`\n${c.red("FAIL")} ${message}`);
  if (hint) console.error(`     ${c.dim(hint)}`);
  process.exit(1);
}

function loadEnv(): Credentials {
  const envFile = path.join(REPO, ".env");
  if (fs.existsSync(envFile)) {
    for (const line of fs.readFileSync(envFile, "utf8").split("\n")) {
      const match = /^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
      if (!match) continue;
      const [, name, rawValue] = match;
      if (name && rawValue !== undefined && !process.env[name]) {
        process.env[name] = rawValue.replace(/^["']|["']$/g, "");
      }
    }
  }

  const { ASC_KEY_ID: keyId, ASC_ISSUER_ID: issuerId, ASC_KEY_PATH: keyPath } = process.env;

  const missing = (
    [
      ["ASC_KEY_ID", keyId],
      ["ASC_ISSUER_ID", issuerId],
      ["ASC_KEY_PATH", keyPath],
    ] as const
  )
    .filter(([, value]) => !value)
    .map(([name]) => name);

  if (missing.length > 0) {
    die(
      `missing ${missing.join(", ")}`,
      "Set them in the environment or in a .env at the repo root (.env is gitignored)."
    );
  }
  // The filter above proves these are set, but it does so at runtime and the
  // compiler cannot follow that, so assert once here rather than at each use.
  const creds: Credentials = { keyId: keyId!, issuerId: issuerId!, keyPath: keyPath! };

  if (!fs.existsSync(creds.keyPath)) die(`no .p8 at ${creds.keyPath}`);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(creds.issuerId)) {
    die(
      "ASC_ISSUER_ID is not a UUID",
      "It is the Issuer ID above the key list, not the key id itself."
    );
  }
  return creds;
}

/**
 * ES256 JWT. Apple rejects anything over 20 minutes, and rejects the DER
 * signature encoding Node produces by default -- JOSE wants raw r||s, which is
 * what dsaEncoding "ieee-p1363" gives.
 */
function makeToken({ keyId, issuerId, keyPath }: Credentials): string {
  const now = Math.floor(Date.now() / 1000);
  const encode = (value: object): string =>
    Buffer.from(JSON.stringify(value)).toString("base64url");

  const signingInput = [
    encode({ alg: "ES256", kid: keyId, typ: "JWT" }),
    encode({ iss: issuerId, iat: now, exp: now + 19 * 60, aud: "appstoreconnect-v1" }),
  ].join(".");

  const signature = crypto
    .createSign("SHA256")
    .update(signingInput)
    .sign(
      { key: fs.readFileSync(keyPath, "utf8"), dsaEncoding: "ieee-p1363" },
      "base64url"
    );

  return `${signingInput}.${signature}`;
}

async function api<T>(
  token: string,
  method: "GET" | "POST",
  endpoint: string,
  body?: unknown
): Promise<T> {
  const response = await fetch(`https://api.appstoreconnect.apple.com${endpoint}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });

  const text = await response.text();
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return die(
      `${method} ${endpoint} returned non-JSON (HTTP ${response.status})`,
      text.slice(0, 200)
    );
  }

  if (!response.ok) {
    if (response.status === 401) {
      die(
        "authentication rejected (HTTP 401)",
        "Check ASC_KEY_ID matches the .p8 filename, and that the key has not been revoked."
      );
    }
    const errors = (parsed as { errors?: ApiError[] }).errors ?? [];
    const detail = errors.map((e) => `${e.title}: ${e.detail}`).join("; ") || text;
    die(`${method} ${endpoint} failed (HTTP ${response.status})`, detail);
  }

  return parsed as T;
}

function sh(command: string, commandArgs: string[], options: { input?: string } = {}): string {
  return execFileSync(command, commandArgs, {
    encoding: "utf8",
    stdio: options.input === undefined ? ["ignore", "pipe", "inherit"] : ["pipe", "ignore", "inherit"],
    ...(options.input === undefined ? {} : { input: options.input }),
  });
}

// ------------------------------------------------------------------- audit

async function audit(token: string): Promise<AuditResult> {
  console.log(c.bold("\nAudit\n"));

  // 1. Certificate quota. This is the constraint that decides whether this app
  //    can be signed at all, so it is checked first and loudly.
  const certificates = await api<ListResponse<CertificateAttributes>>(
    token,
    "GET",
    `/v1/certificates?filter[certificateType]=${CERT_TYPE}&limit=200`
  );
  const live: Certificate[] = certificates.data.filter((cert) => {
    const expires = cert.attributes.expirationDate;
    return expires === undefined || new Date(expires) > new Date();
  });

  info(`${CERT_TYPE} certificates in use: ${live.length} of ${CERT_QUOTA}`);
  for (const { id, attributes } of live) {
    const expiry = attributes.expirationDate?.slice(0, 10) ?? "?";
    info(`    ${attributes.name ?? id} ${c.dim(`(${attributes.serialNumber ?? id}, expires ${expiry})`)}`);
  }

  const slots = CERT_QUOTA - live.length;
  if (slots <= 0) {
    warn(
      `no ${CERT_TYPE} slots left. A new certificate needs one revoked first -- ` +
        "and revoking one breaks whichever app is signing with it."
    );
    // A new certificate is not actually required. Distribution certificates
    // are per-TEAM; provisioning profiles are per-app. An existing certificate
    // can back a new profile, provided its private key is still to hand --
    // which is the part that is usually lost, since it only ever existed on
    // the machine that generated the CSR.
    info("");
    info("A new certificate may not be needed: a profile can reference an existing one.");
    info("Every distribution certificate on the team, for choosing which:");
    const all = await api<ListResponse<CertificateAttributes>>(
      token,
      "GET",
      "/v1/certificates?limit=200"
    );
    for (const { id, attributes } of all.data) {
      const expires = attributes.expirationDate;
      const dead = expires !== undefined && new Date(expires) <= new Date();
      info(
        `    ${(attributes.certificateType ?? "?").padEnd(20)} ${attributes.name ?? id}` +
          ` ${c.dim(`(expires ${expires?.slice(0, 10) ?? "?"}${dead ? ", EXPIRED" : ""})`)}`
      );
    }
    info("");
  } else {
    ok(
      `${slots} slot${slots === 1 ? "" : "s"} free` +
        (slots === 1 ? " -- this app takes the last one" : "")
    );
  }

  // 2. The App ID has to exist before a profile can reference it.
  const bundles = await api<ListResponse<BundleIdAttributes>>(
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
  ok(`App ID "${BUNDLE_ID}" exists ${c.dim(`(${bundle.attributes.name ?? "unnamed"}, ${bundle.id})`)}`);

  // 3. Push. project.yml declares aps-environment, and a profile minted before
  //    the capability is enabled cannot sign a build that declares it --
  //    email-app lost a build to exactly this.
  // No `limit` here. Apple rejects it on this relationship specifically --
  // "The parameter 'limit' can not be used with this request" -- even though
  // it is accepted on every other list endpoint this script touches.
  const capabilities = await api<ListResponse<CapabilityAttributes>>(
    token,
    "GET",
    `/v1/bundleIds/${bundle.id}/bundleIdCapabilities`
  );
  const enabled = capabilities.data
    .map((capability) => capability.attributes.capabilityType)
    .filter((type): type is string => type !== undefined);

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
  if (enabled.length > 0) info(`capabilities: ${enabled.join(", ")}`);

  // 4. An existing profile of the right name is reused rather than duplicated.
  const profiles = await api<ListResponse<ProfileAttributes>>(token, "GET", "/v1/profiles?limit=200");
  const profile = profiles.data.find((p) => p.attributes.name === PROFILE_NAME);
  if (profile) {
    const { profileType, profileState, expirationDate } = profile.attributes;
    const report = profileState === "ACTIVE" ? ok : warn;
    report(
      `profile "${PROFILE_NAME}" exists ` +
        c.dim(`(${profileType}, ${profileState}, expires ${expirationDate?.slice(0, 10) ?? "?"})`)
    );
  } else {
    info(`no profile named "${PROFILE_NAME}" yet`);
  }

  return { bundle, profile, slots };
}

// ------------------------------------------------------------------ create

async function create(token: string, { bundle, profile, slots }: AuditResult): Promise<BuiltIdentity> {
  console.log(c.bold("\nCreate\n"));
  fs.mkdirSync(OUT_DIR, { recursive: true });

  if (slots <= 0) die("refusing to mint: no certificate slots free (see audit above)");

  const keyPem = path.join(OUT_DIR, "signing-key.pem");
  const csrPath = path.join(OUT_DIR, "signing.csr");
  const p12Path = path.join(OUT_DIR, "identity.p12");
  const p12Password = crypto.randomBytes(18).toString("base64url");

  // Apple wants a 2048-bit RSA CSR. MSYS_NO_PATHCONV stops Git Bash rewriting
  // the -subj value into a Windows path, which silently mangles the subject.
  sh("openssl", ["genrsa", "-out", keyPem, "2048"]);
  execFileSync(
    "openssl",
    ["req", "-new", "-key", keyPem, "-out", csrPath,
     "-subj", "/CN=Autocast Distribution/O=Abel Amare/C=US"],
    { stdio: "ignore", env: { ...process.env, MSYS_NO_PATHCONV: "1" } }
  );
  ok("generated private key and CSR");

  const minted = await api<SingleResponse<CertificateAttributes>>(token, "POST", "/v1/certificates", {
    data: {
      type: "certificates",
      attributes: {
        certificateType: CERT_TYPE,
        csrContent: fs.readFileSync(csrPath, "utf8"),
      },
    },
  });
  const certificateId = minted.data.id;
  ok(`minted certificate ${c.dim(minted.data.attributes.name ?? certificateId)}`);

  const certificateContent = minted.data.attributes.certificateContent;
  if (!certificateContent) die("the API returned a certificate with no content");

  // The API returns the DER certificate inline, base64'd.
  const derPath = path.join(OUT_DIR, "cert.der");
  const pemPath = path.join(OUT_DIR, "cert.pem");
  fs.writeFileSync(derPath, Buffer.from(certificateContent, "base64"));
  sh("openssl", ["x509", "-inform", "DER", "-in", derPath, "-out", pemPath]);

  // -legacy is REQUIRED. OpenSSL 3 defaults to AES-256 + SHA-256 for PKCS#12,
  // which macOS `security` cannot import; it fails with "MAC verification
  // failed during PKCS12 import (wrong password?)", blaming the password.
  sh("openssl", [
    "pkcs12", "-export", "-legacy",
    "-inkey", keyPem, "-in", pemPath,
    "-out", p12Path, "-passout", `pass:${p12Password}`,
  ]);
  ok(`built identity.p12 ${c.dim("(-legacy, so macOS can import it)")}`);

  let profileId: string;
  if (profile) {
    profileId = profile.id;
    info(`reusing existing profile "${PROFILE_NAME}"`);
  } else {
    const created = await api<SingleResponse<ProfileAttributes>>(token, "POST", "/v1/profiles", {
      data: {
        type: "profiles",
        attributes: { name: PROFILE_NAME, profileType: "IOS_APP_STORE" },
        relationships: {
          bundleId: { data: { type: "bundleIds", id: bundle.id } },
          certificates: { data: [{ type: "certificates", id: certificateId }] },
        },
      },
    });
    profileId = created.data.id;
    ok(`created profile "${PROFILE_NAME}"`);
  }

  const fetched = await api<SingleResponse<ProfileAttributes>>(token, "GET", `/v1/profiles/${profileId}`);
  const profileContent = fetched.data.attributes.profileContent;
  if (!profileContent) die("the API returned a profile with no content");

  const profilePath = path.join(OUT_DIR, "profile.mobileprovision");
  fs.writeFileSync(profilePath, Buffer.from(profileContent, "base64"));
  ok("downloaded profile");

  fs.writeFileSync(path.join(OUT_DIR, "p12-password.txt"), `P12_PASSWORD=${p12Password}\n`);
  info(`key material in ${OUT_DIR} ${c.dim("(outside the repo)")}`);

  return { p12Path, profilePath, p12Password };
}

// ----------------------------------------------------------------- secrets

function pushSecrets(
  { p12Path, profilePath, p12Password }: BuiltIdentity,
  { keyId, issuerId, keyPath }: Credentials
): void {
  console.log(c.bold("\nSecrets\n"));

  const set = (name: string, value: string): void => {
    sh("gh", ["secret", "set", name, "-R", REPO_SLUG], { input: value });
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

// -------------------------------------------------------------------- main

const credentials = loadEnv();
const token = makeToken(credentials);
const state = await audit(token);

if (!DO_CREATE) {
  console.log(
    `\n${c.dim("Audit only. Re-run with --create to mint the certificate and profile,")}` +
      `\n${c.dim(`or --create --secrets to also push all 7 secrets to ${REPO_SLUG}.`)}\n`
  );
  process.exit(0);
}

const identity = await create(token, state);
if (DO_SECRETS) pushSecrets(identity, credentials);

console.log(
  `\n${c.green("Done.")} Next: ${c.bold(`gh workflow run ios-testflight.yml -R ${REPO_SLUG}`)}\n`
);
