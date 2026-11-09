// Runs the renderer on this PC instead of Fly (free). Keep it open while videos
// are being made: it checks the queue every 10 s, renders whatever is waiting,
// and goes back to waiting.
//
//   node renderer/local-worker.mjs
//
// The Supabase key is fetched at start with the access token in
// ~/.postpilot/.env and handed to the renderer in memory only.
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const env = Object.fromEntries(
  readFileSync(join(homedir(), ".postpilot", ".env"), "utf8")
    .split(/\r?\n/).filter((l) => l.includes("=")).map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()]),
);
const ref = env.SUPABASE_PROJECT_REF;
const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/api-keys`, { headers: { authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}` } });
if (!res.ok) throw new Error(`could not read the project key: ${res.status}`);
const key = (await res.json()).find((k) => k.name === "service_role")?.api_key;
if (!key) throw new Error("no service_role key");

const here = dirname(fileURLToPath(import.meta.url));
const once = () => new Promise((done) => {
  const p = spawn("node", [join(here, "render.ts")], {
    stdio: "inherit",
    env: { ...process.env, SUPABASE_URL: `https://${ref}.supabase.co`, SUPABASE_SERVICE_ROLE_KEY: key, FLY_MACHINE_ID: "abel-pc" },
  });
  p.on("exit", done);
});

console.log("PC renderer on. Waiting for videos... (Ctrl+C to stop)");
for (;;) {
  await once();
  await new Promise((r) => setTimeout(r, 10_000));
}
