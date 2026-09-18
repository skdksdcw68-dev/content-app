/**
 * "Disconnect" on the TikTok account page.
 *
 * Revokes the grant at TikTok, then forgets the stored tokens and cancels
 * anything still queued for that account. Revoking is best effort -- a token
 * that already died is the outcome we wanted -- so the local side always runs.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { revokeAtTikTok } from "../_shared/tiktok.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

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

    const body = (await request.json().catch(() => ({}))) as { connection_id?: string };
    if (!body.connection_id) throw new PublicError("connection_id is required.");

    // RLS proves ownership: somebody else's connection is simply not visible.
    const { data: connection } = await asUser
      .from("platform_connections")
      .select("id")
      .eq("id", body.connection_id)
      .maybeSingle();
    if (!connection) throw new PublicError("That account is not connected.", 404);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const revoked = await revokeAtTikTok(admin, connection.id);

    const { error } = await asUser.rpc("disconnect_connection", { p_connection: connection.id });
    if (error) throw error;

    return json({ disconnected: true, revoked_at_tiktok: revoked });
  } catch (error) {
    return fail(error);
  }
});
