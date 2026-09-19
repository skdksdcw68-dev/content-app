/**
 * Attaching a person's own video to a post, ready for their approval.
 *
 * Shared by prepare-post (a video picked for a planned day) and content-item
 * (the upload flow), so both paths clear rights, build the variant and reset
 * consent the same way.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { PublicError } from "./http.ts";

export const MEDIA_BUCKET = "media";

export interface AttachInput {
  userId: string;
  brandId: string;
  connection: { id: string; platform: string };
  storagePath: string;
  postId: string;
  caption: string;
  hashtags: string[];
  /** Measured on the phone, where the file is; recorded for validation. */
  durationMs?: number | null;
  width?: number | null;
  height?: number | null;
}

export interface AttachResult {
  postTargetId: string;
  assetId: string;
  byteSize: number;
  mime: string;
}

export async function attachUpload(admin: SupabaseClient, input: AttachInput): Promise<AttachResult> {
  if (!input.storagePath.startsWith(`${input.userId}/`) || input.storagePath.includes("..")) {
    throw new PublicError("That file does not belong to you.", 403);
  }

  const { data: file, error: fileError } = await admin.storage
    .from(MEDIA_BUCKET)
    .download(input.storagePath);
  if (fileError || !file) throw new PublicError("That upload could not be found.", 404);

  const bytes = new Uint8Array(await file.arrayBuffer());
  const checksum = await sha256Hex(bytes);
  const mime = file.type || (input.storagePath.toLowerCase().endsWith(".mov") ? "video/quicktime" : "video/mp4");

  // The person owns what they uploaded, so rights are cleared here -- the one
  // place allowed to make that call.
  const { data: asset, error: assetError } = await admin
    .from("media_assets")
    .insert({
      user_id: input.userId,
      brand_id: input.brandId,
      kind: "video",
      source: "user_upload",
      rights: "cleared",
      storage_bucket: MEDIA_BUCKET,
      storage_path: input.storagePath,
      mime,
      byte_size: bytes.byteLength,
      checksum_sha256: checksum,
      duration_ms: input.durationMs ?? null,
      width: input.width ?? null,
      height: input.height ?? null,
    })
    .select("id")
    .single();
  if (assetError) throw assetError;

  // The publisher reads variants, never the raw asset. An upload is its own.
  const { error: variantError } = await admin.from("asset_variants").insert({
    asset_id: asset.id,
    purpose: "tiktok_video",
    mime,
    storage_path: input.storagePath,
    byte_size: bytes.byteLength,
    checksum_sha256: checksum,
  });
  if (variantError) throw variantError;

  // A generation still running for this post would replace this video when it
  // finished. The person chose their own; stop the machine's.
  await admin
    .from("generation_jobs")
    .update({ status: "cancelled", error: "replaced by your upload", finished_at: new Date().toISOString() })
    .eq("post_id", input.postId)
    .in("status", ["queued", "submitted", "running"]);

  const { error: postError } = await admin
    .from("posts")
    .update({
      status: "needs_approval",
      media_strategy: "user_upload",
      render_tier: "eager",
      failure_reason: null,
    })
    .eq("id", input.postId);
  if (postError) throw postError;

  // One target per post per account. New bytes clear consent: permission was
  // for specific bytes.
  const { data: target, error: targetError } = await admin
    .from("post_targets")
    .upsert({
      user_id: input.userId,
      post_id: input.postId,
      connection_id: input.connection.id,
      platform: input.connection.platform,
      caption: input.caption,
      hashtags: input.hashtags,
      privacy: "SELF_ONLY",
      is_aigc: false,
      state: "pending",
      consent_id: null,
      content_digest: null,
      failure_code: null,
      failure_reason: null,
    }, { onConflict: "post_id,connection_id" })
    .select("id")
    .single();
  if (targetError) throw targetError;

  const { error: clearError } = await admin.from("post_assets").delete().eq("post_target_id", target.id);
  if (clearError) throw clearError;

  // A job queued for the old video must not fire for the new one.
  await admin.from("publish_jobs").delete().eq("post_target_id", target.id).in("state", ["pending", "cancelled", "failed"]);

  const { error: linkError } = await admin.from("post_assets").insert({
    post_target_id: target.id,
    asset_id: asset.id,
    ordinal: 0,
    role: "primary",
  });
  if (linkError) throw linkError;

  return { postTargetId: target.id, assetId: asset.id, byteSize: bytes.byteLength, mime };
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * The same video to one more account. The asset (and its bytes) already
 * exist from attachUpload; this only adds the account's own target, linked to
 * that asset, with consent cleared -- each account is approved on its own.
 */
export async function addTarget(
  admin: SupabaseClient,
  input: { userId: string; postId: string; connection: { id: string; platform: string }; caption: string; hashtags: string[]; assetId: string },
): Promise<string> {
  const { data: target, error } = await admin
    .from("post_targets")
    .upsert({
      user_id: input.userId,
      post_id: input.postId,
      connection_id: input.connection.id,
      platform: input.connection.platform,
      caption: input.caption,
      hashtags: input.hashtags,
      privacy: input.connection.platform === "reels" ? "PUBLIC_TO_EVERYONE" : "SELF_ONLY",
      is_aigc: false,
      state: "pending",
      consent_id: null,
      content_digest: null,
      failure_code: null,
      failure_reason: null,
    }, { onConflict: "post_id,connection_id" })
    .select("id")
    .single();
  if (error) throw error;

  await admin.from("post_assets").delete().eq("post_target_id", target.id);
  const { error: linkError } = await admin.from("post_assets").insert({
    post_target_id: target.id,
    asset_id: input.assetId,
    ordinal: 0,
    role: "primary",
  });
  if (linkError) throw linkError;
  return target.id;
}
