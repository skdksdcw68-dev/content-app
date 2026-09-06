/**
 * What the approval screen has to show before anything is published.
 *
 * TikTok requires that the creator be identified, and that the privacy choice
 * be made from the options their account actually offers right now -- not from
 * a list we remembered. This fetches both, records what was fetched, and hands
 * back only the result. The token stays on the server.
 *
 * Called with the person's own JWT, so RLS decides which connections exist as
 * far as this caller is concerned.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { creatorInfo } from "../_shared/tiktok.ts";

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

    // Ownership is proved by RLS rather than by trusting the id in the body:
    // a connection belonging to somebody else simply is not visible here.
    const { data: connection } = await asUser
      .from("platform_connections")
      .select("id, username, avatar_url")
      .eq("id", body.connection_id)
      .maybeSingle();

    if (!connection) throw new PublicError("That account is not connected.", 404);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const info = await creatorInfo(admin, connection.id);

    // Kept because consent binds to it. When a post is approved we record which
    // snapshot the person was looking at, so there is an answer to "what were
    // they shown" that does not depend on TikTok still returning the same thing.
    const { data: snapshot, error: snapshotError } = await admin
      .from("creator_snapshots")
      .insert({
        connection_id: connection.id,
        username: info.creator_username,
        nickname: info.creator_nickname,
        avatar_url: info.creator_avatar_url,
        privacy_level_options: info.privacy_level_options,
        comment_disabled: info.comment_disabled,
        duet_disabled: info.duet_disabled,
        stitch_disabled: info.stitch_disabled,
        max_video_post_duration_sec: info.max_video_post_duration_sec,
      })
      .select("id")
      .single();

    if (snapshotError) throw snapshotError;

    // The avatar URL TikTok returns expires in about two hours, so the app is
    // given the fresh one rather than whatever was stored at connect time.
    await admin
      .from("platform_connections")
      .update({
        username: info.creator_username,
        display_name: info.creator_nickname,
        avatar_url: info.creator_avatar_url,
        avatar_fetched_at: new Date().toISOString(),
        status: "active",
        last_error: null,
      })
      .eq("id", connection.id);

    return json({
      snapshot_id: snapshot.id,
      username: info.creator_username,
      nickname: info.creator_nickname,
      avatar_url: info.creator_avatar_url,
      privacy_level_options: info.privacy_level_options,
      comment_disabled: info.comment_disabled,
      duet_disabled: info.duet_disabled,
      stitch_disabled: info.stitch_disabled,
      max_video_seconds: info.max_video_post_duration_sec,
    });
  } catch (error) {
    return fail(error);
  }
});
