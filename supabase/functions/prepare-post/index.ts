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
import { attachUpload } from "../_shared/attach.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;


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

    // Two ways in. Either this video is filling a slot the plan already wrote,
    // or it is a one-off somebody picked from their camera roll.
    let postId: string;
    let caption = body.caption ?? "";
    let hashtags = body.hashtags ?? [];

    if (body.post_id) {
      // Read under RLS, so a borrowed id finds nothing rather than being
      // checked and refused -- the same reasoning as the connection lookup.
      const { data: planned } = await asUser
        .from("posts")
        .select("id, brand_id, hook, script, cta, hashtags, status")
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
      if (!caption) caption = [planned.script ?? "", planned.cta ?? ""].filter(Boolean).join(" ");
      if (hashtags.length === 0) hashtags = planned.hashtags ?? [];
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

    const attached = await attachUpload(admin, {
      userId: auth.user.id,
      brandId: connection.brand_id,
      connection,
      storagePath: body.storage_path,
      postId,
      caption,
      hashtags,
    });

    return json({ post_id: postId, post_target_id: attached.postTargetId, asset_id: attached.assetId });
  } catch (error) {
    return fail(error);
  }
});

