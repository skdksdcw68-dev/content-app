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
import { accessToken } from "./tiktok.ts";
import { accountOptions } from "./accounts.ts";
import { uploadShort } from "./youtube.ts";
import { containerStatus, createReel, publishReel } from "./instagram.ts";
import { contentDigest } from "./digest.ts";

const BUCKET = "media";

/** TikTok takes a whole file in one chunk below this. Larger needs splitting,
 *  which is work for a container rather than a request. */
const SINGLE_CHUNK_LIMIT = 60 * 1024 * 1024;

export type PublishMode = "DIRECT_POST" | "UPLOAD_TO_DRAFT";

export interface PublishOutcome {
  /** "inbox": the video reached the creator's TikTok drafts (UPLOAD_TO_DRAFT). */
  state: "published" | "processing" | "failed" | "blocked" | "inbox";
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
    .select("id, post_id, connection_id, platform, caption, hashtags, privacy, disable_comment, disable_duet, disable_stitch, is_aigc, brand_content_toggle, brand_organic_toggle, music_track_id, consent_id, state, provider_publish_id, video_cover_ms")
    .eq("id", targetId)
    .maybeSingle();

  if (!target) return { state: "failed", reason: "post_missing" };
  if (target.state === "published") return { state: "published" };
  if (target.state === "sent_to_inbox") return { state: "inbox" };

  // Already handed to TikTok by an earlier attempt. Starting again would post
  // the same video twice; ask TikTok what became of the first one instead.
  if (target.provider_publish_id && ["submitted", "processing"].includes(target.state)) {
    return await verifyTarget(admin, target.id);
  }
  if (target.provider_publish_id && target.state === "uploading") {
    await fail(admin, target.id, "upload_interrupted",
      "The upload was interrupted. It was not retried automatically so it can't post twice. Pick a new time to try again.");
    return { state: "failed", reason: "upload_interrupted" };
  }
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
    const info = await accountOptions(admin, target.connection_id);
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

  // --- YouTube: one resumable upload, and the video exists ------------------

  if (target.platform === "shorts") {
    await admin.from("post_targets").update({ state: "uploading" }).eq("id", target.id);
    const result = await uploadShort(admin, target.connection_id, {
      bytes,
      mime: variant.mime,
      caption: target.caption ?? "",
      hashtags: target.hashtags ?? [],
      privacy: target.privacy,
      isAIGC: target.is_aigc,
    });
    if (!result.ok || !result.videoId) {
      await fail(admin, target.id, result.code ?? "upload_failed", result.reason);
      return { state: "failed", reason: result.reason };
    }
    await admin.from("post_targets").update({ provider_publish_id: result.videoId }).eq("id", target.id);
    await markPublished(admin, target.id, target.post_id, result.videoId);
    return { state: "published", publishId: result.videoId };
  }

  // --- Instagram: a container Instagram fetches, then publish --------------

  if (target.platform === "reels") {
    // Instagram downloads the video itself, from a link that works for a day.
    const { data: signed } = await admin.storage.from(BUCKET).createSignedUrl(variant.storage_path, 24 * 3600);
    if (!signed?.signedUrl) {
      await fail(admin, target.id, "media_missing", "The video link could not be made.");
      return { state: "failed", reason: "media_missing" };
    }
    const container = await createReel(admin, target.connection_id, {
      videoUrl: signed.signedUrl,
      caption: target.caption ?? "",
      hashtags: target.hashtags ?? [],
    });
    if (!container.ok || !container.containerId) {
      await fail(admin, target.id, container.code ?? "container_failed", container.reason);
      return { state: "failed", reason: container.reason };
    }
    await admin.from("post_targets").update({
      state: "submitted",
      provider_publish_id: container.containerId,
    }).eq("id", target.id);

    // Short clips finish in seconds; anything slower is finished by Verify.
    for (let attempt = 0; attempt < 8; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 5_000));
      const outcome = await finishReel(admin, target.id, target.post_id, target.connection_id, container.containerId);
      if (outcome.state !== "processing") return outcome;
    }
    await admin.from("post_targets").update({ state: "processing" }).eq("id", target.id);
    return { state: "processing", publishId: container.containerId };
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
      is_aigc: target.is_aigc,
    };
    // The frame the person picked as the cover, if they picked one.
    if (typeof target.video_cover_ms === "number" && target.video_cover_ms > 0) {
      (initBody.post_info as Record<string, unknown>).video_cover_timestamp_ms = target.video_cover_ms;
    }
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
    const code = init.error?.code ?? "init_failed";
    await fail(admin, target.id, code, plainReason(code) ?? init.error?.message);
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
    await markPublished(admin, target.id, target.post_id, outcome.publishId);
  } else if (outcome.state === "inbox") {
    await admin.from("post_targets").update({ state: "sent_to_inbox" }).eq("id", target.id);
  } else if (outcome.state === "failed") {
    await fail(admin, target.id, "rejected", outcome.reason);
  }

  return { ...outcome, publishId: init.data.publish_id };
}

/**
 * The Verify step. Asks TikTok once what became of a video it accepted, and
 * records the answer. Called by the scheduler for everything still in flight,
 * so "processing" never stays the last word.
 *
 * A private (SELF_ONLY) post comes back PUBLISH_COMPLETE with no public id --
 * TikTok's confirmation is still the verification.
 */
export async function verifyTarget(admin: SupabaseClient, targetId: string): Promise<PublishOutcome> {
  const { data: target } = await admin
    .from("post_targets")
    .select("id, post_id, connection_id, platform, state, provider_publish_id")
    .eq("id", targetId)
    .maybeSingle();

  if (!target?.provider_publish_id) return { state: "failed", reason: "nothing_to_verify" };
  if (target.state === "published") return { state: "published" };

  if (target.platform === "reels") {
    return await finishReel(admin, target.id, target.post_id, target.connection_id, target.provider_publish_id);
  }
  if (target.platform === "shorts") {
    // A YouTube upload is complete once it returns an id.
    await markPublished(admin, target.id, target.post_id, target.provider_publish_id);
    return { state: "published", publishId: target.provider_publish_id };
  }

  const token = await accessToken(admin, target.connection_id);
  const status = await fetchStatus(token, target.provider_publish_id);

  if (status.state === "published") {
    await markPublished(admin, target.id, target.post_id, status.publishId);
    return { state: "published", publishId: target.provider_publish_id };
  }
  if (status.state === "failed") {
    await fail(admin, target.id, "rejected", status.reason);
    return status;
  }
  if (status.state === "inbox") {
    await admin.from("post_targets").update({ state: "sent_to_inbox" }).eq("id", target.id);
    return status;
  }
  if (target.state === "submitted" && status.reason === "PROCESSING_DOWNLOAD") {
    await admin.from("post_targets").update({ state: "processing" }).eq("id", target.id);
  }
  return { state: "processing", publishId: target.provider_publish_id };
}

/** An Instagram container: publish it once FINISHED, record a failure if
 *  Instagram gave up, otherwise say it is still processing. */
async function finishReel(
  admin: SupabaseClient,
  targetId: string,
  postId: string,
  connectionId: string,
  containerId: string,
): Promise<PublishOutcome> {
  const status = await containerStatus(admin, connectionId, containerId);
  if (status.status === "FINISHED") {
    const published = await publishReel(admin, connectionId, containerId);
    if (!published.ok || !published.mediaId) {
      await fail(admin, targetId, published.code ?? "publish_failed", published.reason);
      return { state: "failed", reason: published.reason };
    }
    await markPublished(admin, targetId, postId, published.mediaId);
    return { state: "published", publishId: published.mediaId };
  }
  if (status.status === "ERROR" || status.status === "EXPIRED") {
    const reason = status.status === "EXPIRED"
      ? "Instagram waited too long for the video. Pick a new time to try again."
      : `Instagram couldn’t process the video${status.detail ? ` (${status.detail})` : ""}.`;
    await fail(admin, targetId, `container_${status.status.toLowerCase()}`, reason);
    return { state: "failed", reason };
  }
  return { state: "processing", publishId: containerId };
}

async function markPublished(
  admin: SupabaseClient,
  targetId: string,
  postId: string,
  publicId?: string,
): Promise<void> {
  await admin.from("post_targets").update({
    state: "published",
    published_at: new Date().toISOString(),
    provider_post_id: publicId ?? null,
  }).eq("id", targetId);
  await admin.from("posts").update({ status: "posted", failure_reason: null }).eq("id", postId);
}

/** TikTok's refusals, in words a person can act on. */
export function plainReason(code: string): string | undefined {
  switch (code) {
    case "unaudited_client_can_only_post_to_private_accounts":
      return "TikTok only accepts posts from private accounts until it has reviewed Autocast. Set your TikTok account to Private (TikTok → Settings → Privacy), then pick a new time.";
    case "spam_risk_too_many_posts":
      return "TikTok's daily posting limit for this account was reached. Pick a time tomorrow.";
    case "spam_risk_user_banned_from_posting":
      return "TikTok isn't letting this account post right now.";
    case "privacy_level_option_mismatch":
      return "That visibility isn't available on this account any more. Review it again.";
    case "reached_active_user_cap":
      return "TikTok's limit for apps in review was reached today. Try again tomorrow.";
    case "access_token_invalid":
    case "scope_not_authorized":
      return "TikTok needs you to sign in again (You → Accounts).";
    default:
      return undefined;
  }
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
    const status = await fetchStatus(token, publishId);
    if (status.state !== "processing") return status;
  }

  // Still processing. Not a failure -- verifyTarget() on the next ticks
  // records the final answer.
  return { state: "processing" };
}

/** One status/fetch call. `publishId` on a published result is the PUBLIC
 *  post id when TikTok gives one; `reason` on processing is TikTok's status. */
async function fetchStatus(token: string, publishId: string): Promise<PublishOutcome> {
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

  const raw = await response.text();
  let body: { data?: { status?: string; fail_reason?: string } } = {};
  try { body = JSON.parse(raw); } catch { /* treated as still processing */ }

  if (body.data?.status === "PUBLISH_COMPLETE") {
    // The id is an int64; JSON.parse would round it. Read it from the text.
    const id = /"publicaly_available_post_id"\s*:\s*\[\s*"?(\d+)/.exec(raw)?.[1];
    return { state: "published", publishId: id };
  }
  if (body.data?.status === "SEND_TO_USER_INBOX") {
    return { state: "inbox" };
  }
  if (body.data?.status === "FAILED") {
    return { state: "failed", reason: body.data?.fail_reason ?? "TikTok rejected it." };
  }
  return { state: "processing", reason: body.data?.status };
}
