/**
 * Publishing an approved post to TikTok.
 *
 * Two checks happen before a single byte is sent, and both exist because the
 * gap between approving and publishing is where a post can quietly become
 * something the person did not agree to:
 *
 *   1. The digest is recomputed. If the caption or the video changed since
 *      approval, this stops rather than publishing the new version.
 *   2. creator_info is read again. If the approved visibility is no longer
 *      offered, this fails rather than silently posting at a different one.
 *
 * That second rule is the important one. Downgrading a post somebody approved
 * as visible-to-followers into a private one, because their account changed in
 * between, would be the exact failure the consent record exists to prevent.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { accessToken, creatorInfo } from "../_shared/tiktok.ts";
import { contentDigest } from "../_shared/digest.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const BUCKET = "media";

/** TikTok accepts a whole file in one chunk below this. Above it the upload has
 *  to be split, which is work for the media worker rather than a request. */
const SINGLE_CHUNK_LIMIT = 60 * 1024 * 1024;

interface Body {
  post_target_id?: string;
  /** UPLOAD_TO_DRAFT puts it in the creator's TikTok drafts to finish there. */
  mode?: "DIRECT_POST" | "UPLOAD_TO_DRAFT";
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
    const mode = body.mode ?? "DIRECT_POST";
    if (!body.post_target_id) throw new PublicError("post_target_id is required.");

    const { data: target } = await asUser
      .from("post_targets")
      .select("id, post_id, connection_id, platform, caption, hashtags, privacy, disable_comment, disable_duet, disable_stitch, is_aigc, brand_content_toggle, brand_organic_toggle, music_track_id, consent_id, state")
      .eq("id", body.post_target_id)
      .maybeSingle();

    if (!target) throw new PublicError("That post does not exist.", 404);
    if (target.state === "published") throw new PublicError("That has already gone out.", 409);
    if (!target.consent_id) throw new PublicError("That post has not been approved yet.", 409);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    const { data: consent } = await admin
      .from("consent_records")
      .select("id, content_digest, privacy, revoked_at")
      .eq("id", target.consent_id)
      .single();

    if (consent.revoked_at) throw new PublicError("That permission was withdrawn.", 409);

    const { data: connection } = await admin
      .from("platform_connections")
      .select("id, provider_user_id")
      .eq("id", target.connection_id)
      .single();

    // --- has anything changed since they approved it? -----------------------

    const { data: assets } = await admin
      .from("post_assets")
      .select("ordinal, media_assets!inner(id, storage_path, asset_variants(purpose, checksum_sha256, storage_path, byte_size, mime))")
      .eq("post_target_id", target.id)
      .order("ordinal");

    const variants = (assets ?? []).flatMap((row: Record<string, unknown>) => {
      const asset = row.media_assets as {
        asset_variants?: { purpose: string; checksum_sha256: string; storage_path: string; byte_size: number; mime: string }[];
      };
      const variant = asset.asset_variants?.find((v) => v.purpose === "tiktok_video")
        ?? asset.asset_variants?.[0];
      return variant ? [variant] : [];
    });

    if (variants.length === 0) throw new PublicError("There is nothing to publish.", 409);

    const digest = await contentDigest({
      platform: target.platform,
      providerUserId: connection.provider_user_id,
      caption: target.caption ?? "",
      hashtags: target.hashtags ?? [],
      variantChecksums: variants.map((v) => v.checksum_sha256),
      privacy: target.privacy,
      disableComment: target.disable_comment,
      disableDuet: target.disable_duet,
      disableStitch: target.disable_stitch,
      isAIGC: target.is_aigc,
      brandContent: target.brand_content_toggle,
      brandOrganic: target.brand_organic_toggle,
      musicTrackId: target.music_track_id ?? null,
    });

    const approvedDigest = String(consent.content_digest).replace(/^\\x/, "");
    if (digest !== approvedDigest) {
      await admin
        .from("post_targets")
        .update({ state: "needs_reapproval" })
        .eq("id", target.id);
      throw new PublicError(
        "This changed after you approved it, so it was not posted. Look at it again.",
        409,
      );
    }

    // --- does the account still allow it? -----------------------------------

    if (mode === "DIRECT_POST") {
      const info = await creatorInfo(admin, target.connection_id);
      if (!info.privacy_level_options.includes(target.privacy)) {
        await admin.from("post_targets").update({
          state: "failed",
          failure_code: "privacy_no_longer_available",
          failure_reason: `Your account no longer offers ${target.privacy}. It was not posted at a different visibility.`,
        }).eq("id", target.id);
        throw new PublicError(
          `Your account no longer offers ${target.privacy}, so nothing was posted.`,
          409,
        );
      }
    }

    // --- send it ------------------------------------------------------------

    const variant = variants[0];
    const { data: file, error: fileError } = await admin.storage
      .from(BUCKET)
      .download(variant.storage_path);
    if (fileError || !file) throw new PublicError("The video could not be read.", 500);

    const bytes = new Uint8Array(await file.arrayBuffer());
    if (bytes.byteLength > SINGLE_CHUNK_LIMIT) {
      throw new PublicError("That video is too large to publish from here yet.", 413);
    }

    const token = await accessToken(admin, target.connection_id);

    const caption = [target.caption ?? "", ...(target.hashtags ?? [])]
      .filter(Boolean)
      .join(" ")
      .slice(0, 2200);

    const initBody: Record<string, unknown> = {
      source_info: {
        source: "FILE_UPLOAD",
        video_size: bytes.byteLength,
        chunk_size: bytes.byteLength,
        total_chunk_count: 1,
      },
    };

    // A draft carries no post_info at all -- the creator makes those choices in
    // TikTok itself, which is the whole point of sending it there.
    if (mode === "DIRECT_POST") {
      initBody.post_info = {
        title: caption,
        privacy_level: target.privacy,
        disable_comment: target.disable_comment,
        disable_duet: target.disable_duet,
        disable_stitch: target.disable_stitch,
        brand_content_toggle: target.brand_content_toggle,
        brand_organic_toggle: target.brand_organic_toggle,
      };
    }

    const endpoint = mode === "DIRECT_POST"
      ? "https://open.tiktokapis.com/v2/post/publish/video/init/"
      : "https://open.tiktokapis.com/v2/post/publish/inbox/video/init/";

    const initResponse = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json; charset=UTF-8",
      },
      body: JSON.stringify(initBody),
    });

    const init = await initResponse.json() as {
      data?: { publish_id?: string; upload_url?: string };
      error?: { code?: string; message?: string };
    };

    if (!initResponse.ok || !init.data?.publish_id || !init.data?.upload_url) {
      await recordFailure(admin, target.id, init.error?.code ?? "init_failed", init.error?.message);
      throw new PublicError(init.error?.message ?? "TikTok would not accept the post.", 502);
    }

    await admin.from("post_targets").update({
      state: "uploading",
      provider_publish_id: init.data.publish_id,
    }).eq("id", target.id);

    const upload = await fetch(init.data.upload_url, {
      method: "PUT",
      headers: {
        "Content-Type": variant.mime || "video/mp4",
        "Content-Length": String(bytes.byteLength),
        "Content-Range": `bytes 0-${bytes.byteLength - 1}/${bytes.byteLength}`,
      },
      body: bytes,
    });

    if (!upload.ok) {
      const detail = await upload.text();
      await recordFailure(admin, target.id, "upload_failed", detail.slice(0, 300));
      throw new PublicError("The video could not be uploaded to TikTok.", 502);
    }

    await admin.from("post_targets").update({ state: "submitted" }).eq("id", target.id);

    // TikTok accepts, then moderates. A post can look fine here and be rejected
    // minutes later, so this polls briefly for a real answer rather than
    // reporting success the moment the upload returns.
    const outcome = await pollStatus(token, init.data.publish_id);

    if (outcome.status === "published") {
      await admin.from("post_targets").update({
        state: "published",
        published_at: new Date().toISOString(),
        provider_post_id: outcome.postId ?? null,
      }).eq("id", target.id);
      await admin.from("posts").update({ status: "posted" }).eq("id", target.post_id);
    } else if (outcome.status === "failed") {
      await recordFailure(admin, target.id, outcome.reason ?? "rejected", outcome.reason);
    }

    return json({
      publish_id: init.data.publish_id,
      mode,
      state: outcome.status,
      reason: outcome.reason ?? null,
      privacy: target.privacy,
    });
  } catch (error) {
    return fail(error);
  }
});

async function recordFailure(
  admin: ReturnType<typeof createClient>,
  targetId: string,
  code: string,
  reason?: string,
): Promise<void> {
  await admin.from("post_targets").update({
    state: "failed",
    failure_code: code,
    failure_reason: reason ?? code,
  }).eq("id", targetId);
}

/**
 * Waits for TikTok to finish processing, within the time a request has.
 * Anything still processing when this gives up is reported as such rather than
 * as success -- the app can ask again.
 */
async function pollStatus(
  token: string,
  publishId: string,
): Promise<{ status: "published" | "processing" | "failed"; reason?: string; postId?: string }> {
  for (let attempt = 0; attempt < 12; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, attempt === 0 ? 2_000 : 5_000));

    const response = await fetch(
      "https://open.tiktokapis.com/v2/post/publish/status/fetch/",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json; charset=UTF-8",
        },
        body: JSON.stringify({ publish_id: publishId }),
      },
    );

    const body = await response.json() as {
      data?: { status?: string; fail_reason?: string; publicaly_available_post_id?: string[] };
      error?: { code?: string; message?: string };
    };

    const status = body.data?.status;
    if (status === "PUBLISH_COMPLETE") {
      return { status: "published", postId: body.data?.publicaly_available_post_id?.[0] };
    }
    if (status === "FAILED") {
      return { status: "failed", reason: body.data?.fail_reason ?? "TikTok rejected it." };
    }
  }

  return { status: "processing" };
}
