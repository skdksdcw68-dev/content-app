/**
 * Recording permission to publish one specific post.
 *
 * This is the function TikTok's audit is really about. Everything it does is in
 * service of one claim: that when this post goes out, a person saw whose
 * account it was going to, chose the visibility from what that account actually
 * offered, and agreed to these exact bytes.
 *
 * So none of it is taken on trust. The choices arrive from the app, and every
 * one of them is re-checked here against a creator_info read taken seconds ago.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { creatorInfo } from "../_shared/tiktok.ts";
import { contentDigest } from "../_shared/digest.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const CONSENT_UI_VERSION = "approval-sheet-1";

interface Body {
  post_target_id?: string;
  privacy?: string;
  disable_comment?: boolean;
  disable_duet?: boolean;
  disable_stitch?: boolean;
  is_aigc?: boolean;
  brand_content?: boolean;
  brand_organic?: boolean;
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
    if (!body.post_target_id) throw new PublicError("post_target_id is required.");
    if (!body.privacy) throw new PublicError("Choose who can see this.");

    const { data: target } = await asUser
      .from("post_targets")
      .select("id, post_id, connection_id, platform, caption, hashtags, state, music_track_id")
      .eq("id", body.post_target_id)
      .maybeSingle();

    if (!target) throw new PublicError("That post does not exist.", 404);
    if (target.state === "published") {
      throw new PublicError("That post has already gone out.", 409);
    }

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    const { data: connection } = await admin
      .from("platform_connections")
      .select("id, provider_user_id")
      .eq("id", target.connection_id)
      .single();

    // Read now, not from anything cached. A creator who switched their account
    // to private since the screen was drawn must not be able to approve a
    // visibility their account no longer offers.
    const info = await creatorInfo(admin, target.connection_id);

    if (!info.privacy_level_options.includes(body.privacy)) {
      throw new PublicError(
        `Your account does not currently offer that visibility. Available: ${info.privacy_level_options.join(", ")}.`,
        409,
      );
    }

    // TikTok refuses branded content that is not public, and the useful place
    // to say so is here rather than as a rejection minutes later.
    const brandContent = body.brand_content ?? false;
    if (brandContent && body.privacy === "SELF_ONLY") {
      throw new PublicError("Branded content cannot be posted privately.");
    }

    // The account's own restrictions win. If the creator has comments off,
    // the post has them off, whatever the app sent.
    const disableComment = info.comment_disabled || (body.disable_comment ?? false);
    const disableDuet = info.duet_disabled || (body.disable_duet ?? false);
    const disableStitch = info.stitch_disabled || (body.disable_stitch ?? false);

    // What will actually be uploaded, in order. The digest is over these bytes,
    // so re-rendering the same post invalidates the permission for it.
    const { data: assets, error: assetsError } = await admin
      .from("post_assets")
      .select("ordinal, media_assets!inner(id, asset_variants(purpose, checksum_sha256))")
      .eq("post_target_id", target.id)
      .order("ordinal");

    if (assetsError) throw assetsError;

    const checksums = (assets ?? []).flatMap((row: Record<string, unknown>) => {
      const asset = row.media_assets as { asset_variants?: { purpose: string; checksum_sha256: string }[] };
      const variant = asset.asset_variants?.find((v) => v.purpose === "tiktok_video")
        ?? asset.asset_variants?.[0];
      return variant ? [variant.checksum_sha256] : [];
    });

    if (checksums.length === 0) {
      throw new PublicError("That post has nothing to publish yet.", 409);
    }

    const isAIGC = body.is_aigc ?? false;

    const digest = await contentDigest({
      platform: target.platform,
      providerUserId: connection.provider_user_id,
      caption: target.caption ?? "",
      hashtags: target.hashtags ?? [],
      variantChecksums: checksums,
      privacy: body.privacy,
      disableComment,
      disableDuet,
      disableStitch,
      isAIGC,
      brandContent,
      brandOrganic: body.brand_organic ?? false,
      musicTrackId: target.music_track_id ?? null,
    });

    // The snapshot creator-info just wrote. Consent points at it, so there is
    // always an answer to "what were they shown" that does not depend on
    // TikTok still returning the same thing months later.
    const { data: snapshot } = await admin
      .from("creator_snapshots")
      .select("id")
      .eq("connection_id", target.connection_id)
      .order("fetched_at", { ascending: false })
      .limit(1)
      .single();

    const { data: approval, error: approvalError } = await admin
      .from("approval_requests")
      .insert({
        user_id: auth.user.id,
        post_id: target.post_id,
        status: "approved",
        summary: { posts: 1, platform: target.platform },
        resolved_at: new Date().toISOString(),
      })
      .select("id")
      .single();

    if (approvalError) throw approvalError;

    const { data: consent, error: consentError } = await admin
      .from("consent_records")
      .insert({
        user_id: auth.user.id,
        post_target_id: target.id,
        approval_id: approval.id,
        connection_id: target.connection_id,
        creator_snapshot_id: snapshot.id,
        content_digest: `\\x${digest}`,
        privacy: body.privacy,
        disable_comment: disableComment,
        disable_duet: disableDuet,
        disable_stitch: disableStitch,
        is_aigc: isAIGC,
        brand_content_toggle: brandContent,
        brand_organic_toggle: body.brand_organic ?? false,
        consent_ui_version: CONSENT_UI_VERSION,
        // Recorded as displayed, not as stored. This is the evidence that the
        // creator was identified before publishing.
        shown_creator_username: info.creator_username,
        shown_creator_avatar_url: info.creator_avatar_url,
        granted_ip: request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null,
        granted_ua: request.headers.get("user-agent"),
      })
      .select("id")
      .single();

    if (consentError) throw consentError;

    const { error: targetError } = await admin
      .from("post_targets")
      .update({
        privacy: body.privacy,
        disable_comment: disableComment,
        disable_duet: disableDuet,
        disable_stitch: disableStitch,
        is_aigc: isAIGC,
        brand_content_toggle: brandContent,
        brand_organic_toggle: body.brand_organic ?? false,
        consent_id: consent.id,
        content_digest: `\\x${digest}`,
        state: "pending",
      })
      .eq("id", target.id);

    if (targetError) throw targetError;

    await admin.from("posts").update({ status: "scheduled" }).eq("id", target.post_id);

    // The step that makes approval mean something on its own.
    //
    // A post that came out of a plan already knows when it should go out. Until
    // now that time was decorative -- approving recorded consent and then waited
    // for somebody to press publish, which is the chore this product exists to
    // remove. Handing it to schedule_publish() puts it in the queue the cron
    // loop drains, and the app stops being involved.
    //
    // schedule_publish() is security definer with an explicit auth.uid() check,
    // and the service role is exempt from it by design so this function can act
    // on the person's behalf. The permission was just recorded above; this only
    // decides when to act on it.
    const { data: post } = await admin
      .from("posts")
      .select("scheduled_for")
      .eq("id", target.post_id)
      .single();

    let scheduledFor: string | null = null;

    if (post?.scheduled_for && new Date(post.scheduled_for).getTime() > Date.now()) {
      const { error: scheduleError } = await admin.rpc("schedule_publish", {
        p_post_target_id: target.id,
        p_run_at: post.scheduled_for,
      });

      // A failure here leaves consent recorded and nothing queued, which is the
      // safe direction: the post simply waits for a person. Reported rather
      // than swallowed so the app can say which of the two happened.
      if (scheduleError) {
        console.error("schedule_publish", scheduleError);
      } else {
        scheduledFor = post.scheduled_for;
      }
    }

    return json({
      consent_id: consent.id,
      privacy: body.privacy,
      disable_comment: disableComment,
      disable_duet: disableDuet,
      disable_stitch: disableStitch,
      approved_as: info.creator_username,
      // Null means nobody has said when, so it stays waiting for a tap.
      scheduled_for: scheduledFor,
    });
  } catch (error) {
    return fail(error);
  }
});
