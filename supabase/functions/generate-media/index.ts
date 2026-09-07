/**
 * "Make the video for this day."
 *
 * The one thing the product promised and could not do. A planned post carries a
 * `concept` -- one sentence describing the shot -- and this hands that to the
 * generator the person connected, then returns immediately. Generation takes
 * minutes; nothing waits on it.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { startJob } from "../_shared/generate.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

/** Where Higgsfield calls back. Its own project URL, because a webhook has to
 *  be reachable from the open internet and nothing else here is. */
const WEBHOOK_BASE = Deno.env.get("PUBLIC_FUNCTIONS_URL") ?? `${SUPABASE_URL}/functions/v1`;

interface Body {
  post_id?: string;
  /** Overrides what the planner wrote, for when it wrote something wrong. */
  prompt?: string;
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
    if (!body.post_id) throw new PublicError("post_id is required.");

    // Read under RLS: a borrowed id finds nothing rather than being checked.
    const { data: post } = await asUser
      .from("posts")
      .select("id, brand_id, hook, concept, script, status")
      .eq("id", body.post_id)
      .maybeSingle();

    if (!post) throw new PublicError("That post does not exist.", 404);
    if (post.status === "posted") throw new PublicError("That post has already gone out.", 409);
    if (post.status === "sourcing") {
      throw new PublicError("That one is already being made.", 409);
    }

    // The concept is the instruction; the hook is what gets said. Falling back
    // to the hook is better than refusing, because a post with only a hook is
    // still a post somebody wants a video for.
    const prompt = (body.prompt ?? post.concept ?? "").trim() || post.hook;
    if (!prompt) throw new PublicError("There is nothing here saying what the video should show.");

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    const { jobId, requestId } = await startJob(admin, {
      userId: auth.user.id,
      postId: post.id,
      brandId: post.brand_id,
      prompt,
      webhookBase: WEBHOOK_BASE,
    });

    return json({ job_id: jobId, request_id: requestId, prompt });
  } catch (error) {
    return fail(error);
  }
});
