// TestFlight groups and testers, from Windows.
//
//   npm run testflight              audit only. No writes.
//   npm run testflight:add -- --group "Friends" --testers "a@b.com,c@d.com"
//
// Adding a tester by email creates an EXTERNAL tester. External testing needs
// the build to clear Beta App Review before anyone can install it; internal
// testers skip review but have to be users on the App Store Connect team
// first, which is a Users and Access job this cannot do for you.
//
// Auth is the same App Store Connect key the signing script uses -- read from
// .env, never committed.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const BUNDLE_ID = "Autocast";

// ------------------------------------------------------------------ plumbing

interface Credentials {
  keyId: string;
  issuerId: string;
  keyPath: string;
}

function die(message: string, detail?: string): never {
  console.error(`\n  ${message}`);
  if (detail) console.error(`  ${detail}`);
  process.exit(1);
}

/** Reads .env by hand rather than pulling in a dependency for four lines. */
function readCredentials(): Credentials {
  const envPath = path.join(process.cwd(), ".env");
  if (!fs.existsSync(envPath)) die("no .env found");

  const values: Record<string, string> = {};
  for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
    const match = /^([A-Z_]+)=(.*)$/.exec(line.trim());
    const key = match?.[1];
    if (key) values[key] = match?.[2] ?? "";
  }

  const creds = {
    keyId: values.ASC_KEY_ID ?? "",
    issuerId: values.ASC_ISSUER_ID ?? "",
    keyPath: values.ASC_KEY_PATH ?? "",
  };

  for (const [name, value] of Object.entries(creds)) {
    if (!value) die(`.env is missing a value for ${name}`);
  }
  if (!fs.existsSync(creds.keyPath)) die(`no .p8 at ${creds.keyPath}`);

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
    .sign({ key: fs.readFileSync(keyPath, "utf8"), dsaEncoding: "ieee-p1363" }, "base64url");

  return `${signingInput}.${signature}`;
}

async function api<T>(
  token: string,
  method: "GET" | "POST" | "DELETE",
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

  if (response.status === 204) return undefined as T;

  const text = await response.text();
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    die(`${method} ${endpoint} returned non-JSON (HTTP ${response.status})`, text.slice(0, 200));
  }

  if (!response.ok) {
    const errors = (parsed as { errors?: { title?: string; detail?: string }[] }).errors ?? [];
    const summary = errors.map((e) => `${e.title}: ${e.detail}`).join("; ");
    die(`${method} ${endpoint} failed (HTTP ${response.status})`, summary || text.slice(0, 300));
  }

  return parsed as T;
}

// -------------------------------------------------------------------- shapes

interface Resource<A> {
  id: string;
  attributes: A;
}

interface Listed<A> {
  data: Resource<A>[];
}

interface AppAttributes {
  name: string;
  bundleId: string;
}

interface BuildAttributes {
  version: string;
  processingState: string;
  uploadedDate: string;
  expired: boolean;
}

interface GroupAttributes {
  name: string;
  isInternalGroup: boolean;
  publicLinkEnabled: boolean | null;
  publicLink: string | null;
}

interface TesterAttributes {
  firstName: string | null;
  lastName: string | null;
  email: string | null;
  state: string | null;
}

// --------------------------------------------------------------------- audit

async function findApp(token: string): Promise<Resource<AppAttributes>> {
  const apps = await api<Listed<AppAttributes>>(
    token,
    "GET",
    `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}&limit=10`
  );
  const app = apps.data[0];
  if (!app) die(`no app on this account with bundle id ${BUNDLE_ID}`);
  return app;
}

async function audit(token: string, appId: string): Promise<void> {
  const builds = await api<Listed<BuildAttributes>>(
    token,
    "GET",
    `/v1/builds?filter[app]=${appId}&limit=5&sort=-uploadedDate`
  );

  console.log("\n  Builds");
  if (builds.data.length === 0) {
    console.log("    none uploaded");
  }
  for (const build of builds.data) {
    const { version, processingState, uploadedDate, expired } = build.attributes;
    const flags = [processingState, expired ? "expired" : null].filter(Boolean).join(", ");
    console.log(`    ${version.padEnd(6)} ${flags.padEnd(22)} ${uploadedDate}`);
  }

  const groups = await api<Listed<GroupAttributes>>(
    token,
    "GET",
    `/v1/apps/${appId}/betaGroups?limit=50`
  );

  console.log("\n  Beta groups");
  if (groups.data.length === 0) {
    console.log("    none -- there is nowhere to put a tester yet");
  }

  for (const group of groups.data) {
    const kind = group.attributes.isInternalGroup ? "internal" : "external";
    const testers = await api<Listed<TesterAttributes>>(
      token,
      "GET",
      `/v1/betaGroups/${group.id}/betaTesters?limit=200`
    );

    // A group with no build attached shows an empty TestFlight entry, which
    // reads to the tester as a broken invite rather than as "not yet".
    const attached = await api<Listed<BuildAttributes>>(
      token,
      "GET",
      `/v1/betaGroups/${group.id}/builds?limit=10`
    );

    console.log(`    ${group.attributes.name} (${kind}) -- ${testers.data.length} tester(s)`);
    console.log(
      `      builds: ${
        attached.data.length === 0
          ? "NONE ATTACHED"
          : attached.data.map((build) => build.attributes.version).join(", ")
      }`
    );
    if (group.attributes.publicLink) {
      console.log(`      public link: ${group.attributes.publicLink}`);
    }
    for (const tester of testers.data) {
      const name = [tester.attributes.firstName, tester.attributes.lastName]
        .filter(Boolean)
        .join(" ");
      console.log(
        `      ${(tester.attributes.email ?? "?").padEnd(34)} ${(tester.attributes.state ?? "").padEnd(18)} ${name}`
      );
    }
  }
}

// ----------------------------------------------------------------- add flows

async function ensureGroup(
  token: string,
  appId: string,
  name: string,
  { create }: { create: boolean }
): Promise<Resource<GroupAttributes>> {
  const groups = await api<Listed<GroupAttributes>>(
    token,
    "GET",
    `/v1/apps/${appId}/betaGroups?limit=50`
  );

  const existing = groups.data.find(
    (group) => group.attributes.name.toLowerCase() === name.toLowerCase()
  );
  if (existing) {
    console.log(`\n  Using existing group "${existing.attributes.name}"`);
    return existing;
  }

  // Attaching a build must never invent a group. Creating one silently would
  // make an external group nobody asked for, and external means Beta App
  // Review before anyone can install.
  if (!create) {
    die(
      `no beta group named "${name}"`,
      `groups on this app: ${groups.data.map((g) => g.attributes.name).join(", ") || "none"}`
    );
  }

  console.log(`\n  Creating external group "${name}"`);
  const created = await api<{ data: Resource<GroupAttributes> }>(token, "POST", "/v1/betaGroups", {
    data: {
      type: "betaGroups",
      attributes: { name },
      relationships: { app: { data: { type: "apps", id: appId } } },
    },
  });
  return created.data;
}

/**
 * Attaches the newest build that has finished processing. A group with no
 * build attached shows testers an empty TestFlight entry, which looks like the
 * invite was broken.
 */
async function attachLatestBuild(token: string, appId: string, groupId: string): Promise<void> {
  const builds = await api<Listed<BuildAttributes>>(
    token,
    "GET",
    `/v1/builds?filter[app]=${appId}&limit=10&sort=-uploadedDate`
  );

  const usable = builds.data.find(
    (build) => build.attributes.processingState === "VALID" && !build.attributes.expired
  );

  if (!usable) {
    console.log("  No processed build to attach yet -- re-run once processing finishes.");
    return;
  }

  await api(token, "POST", `/v1/betaGroups/${groupId}/relationships/builds`, {
    data: [{ type: "builds", id: usable.id }],
  });
  console.log(`  Attached build ${usable.attributes.version}`);
}

async function addTesters(
  token: string,
  groupId: string,
  entries: { email: string; firstName: string; lastName: string }[]
): Promise<void> {
  for (const entry of entries) {
    try {
      await api(token, "POST", "/v1/betaTesters", {
        data: {
          type: "betaTesters",
          attributes: {
            email: entry.email,
            firstName: entry.firstName,
            lastName: entry.lastName,
          },
          relationships: { betaGroups: { data: [{ type: "betaGroups", id: groupId }] } },
        },
      });
      console.log(`  Invited ${entry.email}`);
    } catch {
      // die() already reported and exited for real failures; this catch only
      // matters if that behaviour is ever softened.
      console.log(`  Could not invite ${entry.email}`);
    }
  }
}

// ---------------------------------------------------------------------- main

const args = process.argv.slice(2);

function flag(name: string): string | undefined {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : undefined;
}

const credentials = readCredentials();
const token = makeToken(credentials);
const app = await findApp(token);

console.log(`\n  ${app.attributes.name} (${app.attributes.bundleId})`);

const testerList = flag("testers");
const shouldAttach = args.includes("--attach");

if (!testerList && !shouldAttach) {
  await audit(token, app.id);
  console.log("\n  Read-only.");
  console.log("    --group NAME --attach                 put the newest build in front of a group");
  console.log("    --group NAME --testers a@b.com,c@d.com  invite people to it\n");
} else if (!testerList) {
  // Attach-only: make the build everyone already has access to actually the
  // newest one.
  const group = await ensureGroup(token, app.id, flag("group") ?? "Internal", { create: false });
  await attachLatestBuild(token, app.id, group.id);
  console.log("");
  await audit(token, app.id);
  console.log("");
} else {
  const groupName = flag("group") ?? "Testers";
  const entries = testerList
    .split(",")
    .map((raw) => raw.trim())
    .filter(Boolean)
    .map((raw) => {
      // email:First:Last, where the names are optional. Apple wants both, so
      // the local part stands in when nothing better was given.
      const parts = raw.split(":");
      const email = parts[0] ?? "";
      return {
        email,
        firstName: parts[1] || email.split("@")[0] || "Tester",
        lastName: parts[2] || "Tester",
      };
    });

  const group = await ensureGroup(token, app.id, groupName, { create: true });
  await attachLatestBuild(token, app.id, group.id);
  await addTesters(token, group.id, entries);

  console.log("");
  await audit(token, app.id);
  console.log("");
}
