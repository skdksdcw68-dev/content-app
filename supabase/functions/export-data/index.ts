/**
 * "Export my data": a ZIP of everything Autocast holds about the person, as
 * JSON, with a README saying what each file is.
 *
 * Every table is read with the person's own JWT, so RLS decides what is in it
 * -- the export can never contain a row they could not already see. Tokens are
 * not in it at all: they live in `private`, which PostgREST cannot reach.
 * The ZIP goes to their own folder in `artifacts` and the phone gets a link
 * that works for an hour.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { strToU8 } from "https://esm.sh/fflate@0.8.2";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { buildZip } from "../_shared/exports.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const TABLES: Array<[string, string]> = [
  ["brands", "Your apps and what Autocast knows about each one"],
  ["brand_settings", "Posting hours, daily limits and autopilot switches"],
  ["brand_memory", "Facts you gave Autocast about your brand"],
  ["content_pillars", "The themes plans are built from"],
  ["content_plans", "Every plan, including archived ones"],
  ["posts", "Every post: idea, hook, caption, CTA, hashtags, schedule"],
  ["post_targets", "Where each post went and what happened"],
  ["media_assets", "Your videos and pictures (details, not the files)"],
  ["platform_connections", "Connected accounts (no tokens -- those are never exported)"],
  ["activity_events", "Everything Autocast did, in order"],
  ["usage_events", "What was used and any recorded cost"],
];

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);
    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const files = [];
    const lines = [
      "Your Autocast data",
      `Exported ${new Date().toISOString()} for account ${auth.user.id}.`,
      "",
      "Each .json file is one table, as rows.",
      "",
    ];
    for (const [table, meaning] of TABLES) {
      const { data, error } = await asUser.from(table).select("*").limit(10000);
      if (error) {
        lines.push(`${table}.json  -- could not be read: ${error.message}`);
        continue;
      }
      files.push({ path: `${table}.json`, bytes: strToU8(JSON.stringify(data ?? [], null, 2)) });
      lines.push(`${table}.json  (${data?.length ?? 0} rows)  ${meaning}`);
    }
    files.unshift({ path: "README.txt", bytes: strToU8(lines.join("\n") + "\n") });

    const { bytes } = buildZip("Autocast export", files);
    const stamp = new Date().toISOString().slice(0, 10);
    const filename = `autocast-export-${stamp}.zip`;
    const path = `${auth.user.id}/exports/${crypto.randomUUID()}/${filename}`;

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { error: uploadError } = await admin.storage.from("artifacts")
      .upload(path, bytes, { contentType: "application/zip", upsert: true });
    if (uploadError) throw new Error(`upload: ${uploadError.message}`);

    const { data: signed, error: signError } = await admin.storage.from("artifacts")
      .createSignedUrl(path, 60 * 60, { download: filename });
    if (signError || !signed) throw new Error(`sign: ${signError?.message}`);

    return json({ url: signed.signedUrl, filename, size: bytes.byteLength });
  } catch (error) {
    return fail(error);
  }
});
