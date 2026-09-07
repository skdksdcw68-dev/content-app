/**
 * Turns a file the person uploaded into a post waiting for their approval.
 *
 * The app puts the video into Storage itself -- it has a session, and the
 * storage policy already scopes every object to its owner's folder. What it
 * cannot do is declare the result publishable: `media_assets` only accepts a
 * client insert with `rights = 'pending'`, on purpose. Clearing rights is a
 * judgement about provenance, and judgements about provenance are made here.
 *
 * For an upload the judgement is easy: the person owns what they uploaded. For
 * a generated or stock asset it will not be, which is why this is a seam rather
 * than a flag the app could have set itself.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const BUCKET = "media";

interface Body {
  connection_id?: string;
  storage_path?: string;
  caption?: string;
  hashtags?: string[];
  /** An existing planned post to fill in, rather than making a new one. This is
   *  what joins the plan to the queue: without it, uploading a video for day 4
   *  creates an unrelated post and day 4 stays empty forever. */
  post_id?: string;
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

    const body = (await request.json().catch(() => ({}))) as Body;
    if (!body.connection_id) throw new PublicError("connection_id is required.");
    if (!body.storage_path) throw new PublicError("storage_path is required.");

    // RLS decides whether this connection exists for this caller, so a borrowed
    // id finds nothing rather than being checked and rejected.
    const { data: connection } = await asUser
      .from("platform_connections")
      .select("id, brand_id, platform")
      .eq("id", body.connection_id)
      .maybeSingle();

    if (!connection) throw new PublicError("That account is not connected.", 404);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // The path is claimed by the caller, so it is checked rather than believed:
    // it has to sit under their own user id, and the object has to exist.
    if (!body.storage_path.startsWith(`${auth.user.id}/`)) {
      throw new PublicError("That file does not belong to you.", 403);
    }

    const { data: file, error: fileError } = await admin.storage
      .from(BUCKET)
      .download(body.storage_path);

    if (fileError || !file) throw new PublicError("That upload could not be found.", 404);

    const bytes = new Uint8Array(await file.arrayBuffer());
    const checksum = await sha256Hex(bytes);

    // Deliberately no transcode. A video straight off a phone is already H.264
    // in an MP4 and inside TikTok's limits; generated media will not be, and
    // that is what the media worker exists for.
    const { data: asset, error: assetError } = await admin
      .from("media_assets")
      .insert({
        user_id: auth.user.id,
        brand_id: connection.brand_id,
        kind: "video",
        source: "user_upload",
        rights: "cleared",
        storage_bucket: BUCKET,
        storage_path: body.storage_path,
        mime: file.type || "video/mp4",
        byte_size: bytes.byteLength,
        checksum_sha256: checksum,
      })
      .select("id")
      .single();

    if (assetError) throw assetError;

    // The publisher reads variants, never the raw asset -- that is what makes
    // "an unconverted file reached the platform" impossible rather than a bug
    // waiting to happen. An upload is its own variant.
    const { error: variantError } = await admin.from("asset_variants").insert({
      asset_id: asset.id,
      purpose: "tiktok_video",
      mime: file.type || "video/mp4",
      storage_path: body.storage_path,
      byte_size: bytes.byteLength,
      checksum_sha256: checksum,
    });
    if (variantError) throw variantError;

    // Two ways in. Either this video is filling a slot the plan already wrote,
    // or it is a one-off somebody picked from their camera roll.
    let postId: string;
    let caption = body.caption ?? "";

    if (body.post_id) {
      // Read under RLS, so a borrowed id finds nothing rather than being
      // checked and refused -- the same reasoning as the connection lookup.
      const { data: planned } = await asUser
        .from("posts")
        .select("id, brand_id, hook, script, status")
        .eq("id", body.post_id)
        .maybeSingle();

      if (!planned) throw new PublicError("That post does not exist.", 404);

      if (planned.brand_id !== connection.brand_id) {
        throw new PublicError("That post belongs to a different brand.", 409);
      }

      if (planned.status === "posted") {
        throw new PublicError("That post has already gone out.", 409);
      }

      // The plan already wrote the caption. Only fall back to it when the
      // person did not type one, so editing on the way in still works.
      if (!caption) caption = planned.script ?? "";

      const { error: updateError } = await admin
        .from("posts")
        .update({
          status: "needs_approval",
          // It came from a plan that intended to generate the media. It did
          // not; the row should say what actually happened.
          media_strategy: "user_upload",
          render_tier: "eager",
        })
        .eq("id", planned.id);

      if (updateError) throw updateError;
      postId = planned.id;
    } else {
      const { data: created, error: postError } = await admin
        .from("posts")
        .insert({
          user_id: auth.user.id,
          brand_id: connection.brand_id,
          format: "video",
          hook: (body.caption ?? "Untitled").slice(0, 60),
          concept: "Uploaded by hand.",
          // Every post says why it exists. For this one the honest answer is
          // that a person chose it, and that is what the row will say.
          rationale: "You picked this video yourself.",
          status: "needs_approval",
          render_tier: "eager",
          media_strategy: "user_upload",
        })
        .select("id")
        .single();

      if (postError) throw postError;
      postId = created.id;
    }

    // One target per post per account -- `unique (post_id, connection_id)`.
    // Upserting rather than inserting means a second upload for the same day
    // replaces the first instead of failing with a constraint violation the
    // person cannot act on.
    const { data: target, error: targetError } = await admin
      .from("post_targets")
      .upsert({
        user_id: auth.user.id,
        post_id: postId,
        connection_id: connection.id,
        platform: connection.platform,
        caption,
        hashtags: body.hashtags ?? [],
        // Safe defaults. Nothing here is a choice the person has made yet --
        // the approval screen is where they make them. Replacing the media has
        // to clear consent too: permission was granted for specific bytes, and
        // these are different bytes.
        privacy: "SELF_ONLY",
        is_aigc: false,
        state: "pending",
        consent_id: null,
        content_digest: null,
      }, { onConflict: "post_id,connection_id" })
      .select("id")
      .single();

    if (targetError) throw targetError;

    // Same reason: whatever was attached before is not what was just uploaded.
    const { error: clearError } = await admin
      .from("post_assets")
      .delete()
      .eq("post_target_id", target.id);

    if (clearError) throw clearError;

    // And a job queued for the old video must not fire for the new one. The
    // publisher would refuse it anyway -- consent is cleared above -- but it
    // would refuse it every minute for ninety minutes and then report a missed
    // window, which reads to a person as a failure rather than a replacement.
    await admin
      .from("publish_jobs")
      .delete()
      .eq("post_target_id", target.id)
      .eq("state", "pending");

    // The trigger on post_assets refuses anything not cleared, so this insert
    // is also the check that the rights decision above actually took.
    const { error: linkError } = await admin.from("post_assets").insert({
      post_target_id: target.id,
      asset_id: asset.id,
      ordinal: 0,
      role: "primary",
    });
    if (linkError) throw linkError;

    return json({ post_id: postId, post_target_id: target.id, asset_id: asset.id });
  } catch (error) {
    return fail(error);
  }
});

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, "0")).join("");
}
