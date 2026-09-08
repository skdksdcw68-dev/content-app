/**
 * The generation pipeline's two halves, shared by every path that touches it.
 *
 * `startJob` submits and returns. `finishJob` takes a job whose provider says it
 * is done and turns the result into something publishable. Both are here rather
 * than in a function because three callers need them -- the manual "make this"
 * button, the webhook, and the poller -- and three copies of "download the
 * bytes and decide the rights" is three places for them to disagree.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { open } from "./crypto.ts";
import { PublicError } from "./http.ts";
import { inspect } from "./media.ts";
import { type Credential, parseCredential, poll, Refused, submit } from "./higgsfield.ts";

const BUCKET = "media";

/** Provider outputs live about a week, so nothing is ever linked. A file over
 *  this is refused rather than silently truncated -- the storage tier caps
 *  uploads at 50MB and a partial video is worse than an error. */
const MAX_BYTES = 45 * 1024 * 1024;

export async function credentialFor(
  admin: SupabaseClient,
  userId: string,
): Promise<{ id: string; credential: Credential; lastGoodModel: string | null }> {
  const { data: rows, error } = await admin.rpc("generator_for_user", { p_user: userId });
  if (error) throw error;

  const row = (rows ?? [])[0];
  if (!row) {
    throw new PublicError(
      "Connect a generator first. You → Generators, and paste your Higgsfield key.",
      409,
    );
  }
  if (row.last_probe_ok === false) {
    throw new PublicError(
      "Your generator key stopped working. Reconnect it under You → Generators.",
      409,
    );
  }

  const secret = await open(row.secret_ct, `${row.id}:provider`);
  return {
    id: row.id,
    credential: parseCredential(secret),
    lastGoodModel: row.last_good_model ?? null,
  };
}

/**
 * Starts making the video for one post.
 *
 * The prompt is the post's `concept` -- the sentence the planner wrote saying
 * what the video should show. That is the whole reason `concept` exists as its
 * own column rather than being folded into the caption: the caption is for
 * people and the concept is an instruction to a machine, and writing one string
 * for both makes it bad at each.
 */
export async function startJob(
  admin: SupabaseClient,
  args: {
    userId: string;
    postId: string;
    brandId: string;
    prompt: string;
    webhookBase: string;
  },
): Promise<{ jobId: string; requestId: string }> {
  const { id: credentialId, credential, lastGoodModel } = await credentialFor(admin, args.userId);

  // The row before the request, so a submission that succeeds and then loses
  // its response still has somewhere to be recovered from. The other order
  // spends the user's money on a job with no record.
  const { data: job, error: jobError } = await admin
    .from("generation_jobs")
    .insert({
      user_id: args.userId,
      brand_id: args.brandId,
      post_id: args.postId,
      kind: "video_generate",
      provider: "higgsfield",
      credential_id: credentialId,
      status: "queued",
      input: { prompt: args.prompt },
    })
    .select("id, webhook_token")
    .single();

  if (jobError) throw jobError;

  try {
    const submitted = await submit(credential, {
      prompt: args.prompt,
      // The token is in the path, not a header: the provider signs nothing, so
      // an unguessable URL is what stops a stranger claiming a job finished.
      // Even so the body is never believed -- see finishJob.
      webhookUrl: `${args.webhookBase}/hf-webhook/${job.webhook_token}`,
      preferModel: lastGoodModel ?? undefined,
    });

    await admin
      .from("generation_jobs")
      .update({
        status: "submitted",
        provider_request_id: submitted.requestId,
        status_url: submitted.statusUrl,
        cancel_url: submitted.cancelUrl,
        submitted_at: new Date().toISOString(),
        // Which model took it, kept on the job so a bad batch can be traced to
        // the model that made it rather than guessed at.
        input: { prompt: args.prompt, model: submitted.model },
        // The webhook is an optimisation. This is the path that guarantees
        // completion, and it exists from the moment the job is submitted.
        poll_after: new Date(Date.now() + 20_000).toISOString(),
      })
      .eq("id", job.id);

    // So tomorrow starts with the model that worked today instead of walking
    // the list again. A hint only -- see 0017.
    if (submitted.model !== lastGoodModel) {
      await admin.rpc("remember_good_model", {
        p_credential_id: credentialId,
        p_model: submitted.model,
      });
    }

    await admin.from("posts").update({ status: "sourcing" }).eq("id", args.postId);

    return { jobId: job.id, requestId: submitted.requestId };
  } catch (error) {
    const detail = error instanceof Error ? error.message : "submission failed";
    // A provider having a bad minute is not a verdict on this post. The job is
    // put back rather than buried, and the caller is told not to fail the post.
    const retryable = error instanceof Refused && error.retryable;
    const failureCode = error instanceof Refused ? error.code : null;

    await admin
      .from("generation_jobs")
      .update(
        retryable
          ? { status: "queued", error: detail, failure_code: failureCode }
          : {
            status: "failed",
            error: detail,
            failure_code: failureCode,
            finished_at: new Date().toISOString(),
          },
      )
      .eq("id", job.id);

    throw new PublicError(detail, 502, retryable, failureCode);
  }
}

export type FinishOutcome =
  | { state: "done"; assetId: string }
  | { state: "waiting" }
  | { state: "failed"; reason: string };

/**
 * Asks the provider what really happened, and if it is finished, keeps it.
 *
 * Called by the webhook and by the poller, and neither passes in a status --
 * both hand over a job id and let this re-read `status_url` with our own key.
 * That is what makes the unsigned webhook safe: the callback is a nudge, and
 * the only thing that can mark a job complete is the provider answering us.
 */
export async function finishJob(
  admin: SupabaseClient,
  jobId: string,
): Promise<FinishOutcome> {
  const { data: job } = await admin
    .from("generation_jobs")
    .select("id, user_id, brand_id, post_id, status, status_url, credential_id, asset_id, input")
    .eq("id", jobId)
    .maybeSingle();

  if (!job) return { state: "failed", reason: "no such job" };
  if (job.status === "succeeded" && job.asset_id) {
    // Duplicate webhook deliveries are documented as possible, so arriving
    // twice has to be free rather than producing two assets.
    return { state: "done", assetId: job.asset_id };
  }
  if (!job.status_url) return { state: "waiting" };

  const { credential } = await credentialFor(admin, job.user_id);
  const result = await poll(credential, job.status_url);

  if (result.status === "queued" || result.status === "in_progress") {
    await admin
      .from("generation_jobs")
      .update({
        status: "running",
        poll_after: new Date(Date.now() + 30_000).toISOString(),
      })
      .eq("id", job.id);
    return { state: "waiting" };
  }

  if (result.status !== "completed") {
    // nsfw is terminal and distinct: retrying the same prompt fails the same
    // way and charges again for the privilege.
    const status = result.status === "nsfw" ? "rejected_nsfw" : "failed";
    const reason = result.status === "nsfw"
      ? "The generator refused that prompt. Edit what the video should show and try again."
      : result.error ?? "The generator could not make that.";

    await admin
      .from("generation_jobs")
      .update({ status, error: reason, poll_after: null, finished_at: new Date().toISOString() })
      .eq("id", job.id);

    await admin
      .from("posts")
      .update({ status: "failed", failure_reason: reason })
      .eq("id", job.post_id);

    return { state: "failed", reason };
  }

  if (!result.videoUrl) {
    return { state: "failed", reason: "The generator said it was done but returned nothing." };
  }

  const assetId = await ingest(admin, {
    jobId: job.id,
    userId: job.user_id,
    brandId: job.brand_id,
    postId: job.post_id,
    url: result.videoUrl,
  });

  await admin
    .from("generation_jobs")
    .update({
      status: "succeeded",
      asset_id: assetId,
      output: { url: result.videoUrl },
      poll_after: null,
      finished_at: new Date().toISOString(),
    })
    .eq("id", job.id);

  return { state: "done", assetId };
}

/**
 * Copies the bytes into our Storage and records what they are.
 *
 * Never a link. The provider keeps output for about seven days, so a plan whose
 * day 30 pointed at a provider URL would find nothing there -- and consent is
 * bound to a checksum, which cannot be taken of something that has expired.
 */
async function ingest(
  admin: SupabaseClient,
  args: { jobId: string; userId: string; brandId: string; postId: string; url: string },
): Promise<string> {
  const response = await fetch(args.url);
  if (!response.ok) {
    throw new PublicError(`Could not download the finished video (${response.status}).`, 502);
  }

  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > MAX_BYTES) {
    throw new PublicError("The generated video is larger than storage allows.", 413);
  }

  const declared = response.headers.get("content-type")?.split(";")[0] ?? "";

  // Before anything is stored, hashed, or bound to consent. Everything
  // downstream reads `asset_variants` and asks no questions, so this is the
  // only place where "is it actually a video" can still be answered -- see
  // media.ts for what a JPEG would otherwise have got away with.
  const checked = inspect(bytes, declared);
  if (!checked.ok) {
    throw new PublicError(
      checked.reason ?? "The generator did not return a usable video.",
      422,
      false,
      "bad_output",
    );
  }

  const mime = checked.container === "webm" ? "video/webm" : "video/mp4";
  const path = `${args.userId}/${args.jobId}/generated.${checked.container === "webm" ? "webm" : "mp4"}`;

  const { error: uploadError } = await admin.storage
    .from(BUCKET)
    .upload(path, bytes, { contentType: mime, upsert: true });

  if (uploadError) throw uploadError;

  const checksum = await sha256Hex(bytes);

  const { data: asset, error: assetError } = await admin
    .from("media_assets")
    .insert({
      user_id: args.userId,
      brand_id: args.brandId,
      kind: "video",
      // Provenance, recorded rather than assumed. `generated` is what makes
      // is_aigc default to true on the post target, which is a disclosure
      // TikTok requires and which nobody should have to remember to tick.
      source: "generated",
      rights: "cleared",
      created_by_job: args.jobId,
      storage_bucket: BUCKET,
      storage_path: path,
      mime,
      byte_size: bytes.byteLength,
      checksum_sha256: checksum,
    })
    .select("id")
    .single();

  if (assetError) throw assetError;

  // The publisher reads variants and never the raw asset, which is what makes
  // "an unconverted file reached the platform" impossible rather than a bug
  // waiting to happen. Higgsfield returns MP4 at the aspect ratio we asked
  // for, so the output is already its own variant -- the day a provider
  // returns something else, this is where the transcode goes.
  const { error: variantError } = await admin.from("asset_variants").insert({
    asset_id: asset.id,
    purpose: "tiktok_video",
    mime,
    storage_path: path,
    byte_size: bytes.byteLength,
    checksum_sha256: checksum,
  });
  if (variantError) throw variantError;

  await attachToPost(admin, {
    userId: args.userId,
    postId: args.postId,
    assetId: asset.id,
  });

  return asset.id;
}

/**
 * Puts the finished video against the day it was made for, and stops there.
 *
 * Deliberately leaves the post at `needs_approval` even when the brand has
 * hands-off enabled. Media that exists and nobody has seen is exactly the case
 * consent cannot cover in advance, and it is the one place in this pipeline
 * where a person is required.
 */
async function attachToPost(
  admin: SupabaseClient,
  args: { userId: string; postId: string; assetId: string },
): Promise<void> {
  const { data: post } = await admin
    .from("posts")
    .select("id, brand_id, script")
    .eq("id", args.postId)
    .single();

  const { data: connection } = await admin
    .from("platform_connections")
    .select("id, platform")
    .eq("brand_id", post.brand_id)
    .eq("status", "active")
    .order("connected_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!connection) {
    // The video is kept -- it was paid for -- and shows up in Library. What
    // cannot happen without an account is a destination for it.
    await admin
      .from("posts")
      .update({ status: "needs_approval" })
      .eq("id", args.postId);
    return;
  }

  const { data: target, error: targetError } = await admin
    .from("post_targets")
    .upsert({
      user_id: args.userId,
      post_id: args.postId,
      connection_id: connection.id,
      platform: connection.platform,
      caption: post.script ?? "",
      privacy: "SELF_ONLY",
      // Generated, so the disclosure is on by default rather than left to
      // somebody remembering. It can still be turned off on the sheet if the
      // person disagrees, which is their call to make and not ours.
      is_aigc: true,
      state: "pending",
      // New bytes, so any permission for the old ones no longer applies.
      consent_id: null,
      content_digest: null,
    }, { onConflict: "post_id,connection_id" })
    .select("id")
    .single();

  if (targetError) throw targetError;

  await admin.from("post_assets").delete().eq("post_target_id", target.id);
  await admin.from("publish_jobs").delete().eq("post_target_id", target.id).eq("state", "pending");

  const { error: linkError } = await admin.from("post_assets").insert({
    post_target_id: target.id,
    asset_id: args.assetId,
    ordinal: 0,
    role: "primary",
  });
  if (linkError) throw linkError;

  await admin.from("posts").update({ status: "needs_approval" }).eq("id", args.postId);
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, "0")).join("");
}
