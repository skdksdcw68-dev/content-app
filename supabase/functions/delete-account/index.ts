/**
 * "Delete account" -- everything, for real, as Apple requires.
 *
 *   1. Revoke every platform grant at the platform, so no token outlives us.
 *   2. Delete the person's files from storage (paths start with their id).
 *   3. Clear the few RESTRICT links, then delete the auth user. Every table
 *      cascades from auth.users, so the rows go with it.
 *
 * The app asks for "DELETE" to be typed before it calls this; the body must
 * carry that same word, so a stray call cannot do it by accident.
 */

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { revokeAtTikTok } from "../_shared/tiktok.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const BUCKETS = ["media", "artifacts"];

async function removeFolder(admin: SupabaseClient, bucket: string, prefix: string): Promise<number> {
  let removed = 0;
  const { data: entries } = await admin.storage.from(bucket).list(prefix, { limit: 1000 });
  const files: string[] = [];
  for (const entry of entries ?? []) {
    const path = `${prefix}/${entry.name}`;
    // Folders come back without an id.
    if (entry.id) files.push(path);
    else removed += await removeFolder(admin, bucket, path);
  }
  if (files.length) {
    const { error } = await admin.storage.from(bucket).remove(files);
    if (error) throw new Error(`remove ${bucket}: ${error.message}`);
    removed += files.length;
  }
  return removed;
}

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
    const userId = auth.user.id;

    const body = (await request.json().catch(() => ({}))) as { confirm?: string };
    if (body.confirm !== "DELETE") throw new PublicError("Type DELETE to confirm.");

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    const { data: connections } = await admin
      .from("platform_connections")
      .select("id, status")
      .eq("user_id", userId);
    for (const connection of connections ?? []) {
      if (connection.status !== "revoked") await revokeAtTikTok(admin, connection.id);
    }

    let files = 0;
    for (const bucket of BUCKETS) files += await removeFolder(admin, bucket, userId);

    const { error: linksError } = await admin.rpc("clear_account_links", { p_user: userId });
    if (linksError) throw new Error(`clear_account_links: ${linksError.message}`);

    const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
    if (deleteError) throw new Error(`deleteUser: ${deleteError.message}`);

    return json({ deleted: true, files_removed: files, accounts_revoked: connections?.length ?? 0 });
  } catch (error) {
    return fail(error);
  }
});
