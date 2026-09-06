/**
 * Publishing one approved post.
 *
 * Extracted so the manual path and the scheduler run exactly the same code. A
 * scheduler that publishes through a second, slightly different implementation
 * is a scheduler that will one day post something the manual path would have
 * refused.
 *
 * Two checks happen before a byte is sent, and both exist because the gap
 * between approving and publishing is where a post can quietly become something
 * nobody agreed to:
 *
 *   1. The digest is recomputed. If the caption or the video changed since
 *      approval, this stops rather than publishing the new version.
 *   2. creator_info is read again. If the approved visibility is no longer
 *      offered, this fails rather than silently posting at a different one.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { accessToken, creatorInfo } from "./tiktok.ts";
import { contentDigest } from "./digest.ts";

const BUCKET = "media";

/** TikTok takes a whole file in one chunk below this. Larger needs splitting,
 *  which is work for a container rather than a request. */
const SINGLE_CHUNK_LIMIT = 60 * 1024 * 1024;

export type PublishMode = "DIRECT_POST" | "UPLOAD_TO_DRAFT";

export interface PublishOutcome {
  state: "published" | "processing" | "failed" | "blocked";
  reason?: string;
  publishId?: string;
}

/**
 * `blocked` is separate from `failed` on purpose: it means a person has to look
 * at it, not that something went wrong. The scheduler treats the two
 * differently -- a blocked post waits, a failed one stops.
 */
export async function publishTarget(
  admin: SupabaseClient,
  targetId: string,
  mode: PublishMode,
): Promise<PublishOutcome> {
  const { data: target } = await admin
    .from("post_targets")
    .select("id, post_id, connection_id, platform, caption, hashtags, privacy, disable_comment, disable_duet, disable_stitch, is_aigc, brand_content_toggle, brand_organic_toggle, music_track_id, consent_id, state")
    .eq("id", targetId)
    .maybeSingle();

  if (!target) return { state: "failed", reason: "post_missing" };
  if (target.state === "published") return { state: "published" };
  if (!target.consent_id) return { state: "blocked", reason: "not_approved" };

  const { data: consent } = await admin
    .from("consent_records")
    .select("id, content_digest, revoked_at")
    .eq("id", target.consent_id)
    .single();

  if (consent.revoked_at) {
    await fail(admin, target.id, "consent_revoked", "That permission was withdrawn.");
    return { state: "failed", reason: "consent_revoked" };
  }

  const { data: connection } = await admin
    .from("platform_connections")
    .select("id, provider_user_id, status")
    .eq("id", target.connection_id)
    .single();

  if (connection.status !== "active") {
    return { state: "blocked", reason: "connection_unhealthy" };
  }

  // --- has anything changed since they approved it? -------------------------

  const { data: assets } = await admin
    .from("post_assets")
    .select("ordinal, media_assets!inner(id, asset_variants(purpose, checksum_sha256, storage_path, byte_size, mime))")
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

  if (variants.length === 0) return { state: "blocked", reason: "no_media" };

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

  if (digest !== String(consent.content_digest).replace(/^\\x/, "")) {
    await admin.from("post_targets").update({ state: "needs_reapproval" }).eq("id", target.id);
    return { state: "blocked", reason: "changed_since_approval" };
  }

  // --- does the account still allow it? -------------------------------------

  if (mode === "DIRECT_POST") {
    const info = await creatorInfo(admin, target.connection_id);
    if (!info.privacy_level_options.includes(target.privacy)) {
      await fail(
        admin,
        target.id,
        "privacy_no_longer_available",
        `Your account no longer offers ${target.privacy}. It was not posted at a different visibility.`,
      );
      return { state: "failed", reason: "privacy_no_longer_available" };
    }
  }

  // --- send it --------------------------------------------------------------

  const variant = variants[0];
  const { data: file } = await admin.storage.from(BUCKET).download(variant.storage_path);
  if (!file) {
    await fail(admin, target.id, "media_missing", "The video could not be read.");
    return { state: "failed", reason: "media_missing" };
  }

  const bytes = new Uint8Array(await file.arrayBuffer());
  if (bytes.byteLength > SINGLE_CHUNK_LIMIT) {
    await fail(admin, target.id, "too_large", "That video is too large to publish from here yet.");
    return { state: "failed", reason: "too_large" };
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
    await fail(admin, target.id, init.error?.code ?? "init_failed", init.error?.message);
    return { state: "failed", reason: init.error?.message ?? "init_failed" };
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
    await fail(admin, target.id, "upload_failed", detail.slice(0, 300));
    return { state: "failed", reason: "upload_failed" };
  }

  await admin.from("post_targets").update({ state: "submitted" }).eq("id", target.id);

  // TikTok accepts, then moderates. A post can look fine here and be rejected
  // minutes later, so this waits for a real answer rather than calling the
  // upload returning success.
  const outcome = await pollStatus(token, init.data.publish_id);

  if (outcome.state === "published") {
    await admin.from("post_targets").update({
      state: "published",
      published_at: new Date().toISOString(),
      provider_post_id: outcome.publishId ?? null,
    }).eq("id", target.id);
    await admin.from("posts").update({ status: "posted" }).eq("id", target.post_id);
  } else if (outcome.state === "failed") {
    await fail(admin, target.id, "rejected", outcome.reason);
  }

  return { ...outcome, publishId: init.data.publish_id };
}

async function fail(
  admin: SupabaseClient,
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

async function pollStatus(token: string, publishId: string): Promise<PublishOutcome> {
  for (let attempt = 0; attempt < 10; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, attempt === 0 ? 2_000 : 4_000));

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
    };

    if (body.data?.status === "PUBLISH_COMPLETE") {
      return { state: "published", publishId: body.data?.publicaly_available_post_id?.[0] };
    }
    if (body.data?.status === "FAILED") {
      return { state: "failed", reason: body.data?.fail_reason ?? "TikTok rejected it." };
    }
  }

  // Still processing. Not a failure -- the status poller will catch up.
  return { state: "processing" };
}
