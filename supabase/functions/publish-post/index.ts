/**
 * Publishing on demand, from the approval sheet.
 *
 * All the actual work lives in _shared/publish.ts, which the scheduler uses too.
 * A scheduler running through a second, slightly different implementation is a
 * scheduler that will one day post something this path would have refused.
 *
 * What this adds is the ownership check: RLS decides whether the post exists for
 * this caller before anything is sent.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { publishTarget, type PublishMode } from "../_shared/publish.ts";

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

    const body = (await request.json().catch(() => ({}))) as {
      post_target_id?: string;
      mode?: PublishMode;
    };
    if (!body.post_target_id) throw new PublicError("post_target_id is required.");

    const { data: target } = await asUser
      .from("post_targets")
      .select("id")
      .eq("id", body.post_target_id)
      .maybeSingle();

    if (!target) throw new PublicError("That post does not exist.", 404);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const outcome = await publishTarget(admin, target.id, body.mode ?? "DIRECT_POST");

    if (outcome.state === "blocked") {
      throw new PublicError(explain(outcome.reason), 409);
    }

    return json({ state: outcome.state, reason: outcome.reason ?? null });
  } catch (error) {
    return fail(error);
  }
});

/** Reasons a person can act on, in words they can act on. */
function explain(reason?: string): string {
  switch (reason) {
    case "changed_since_approval":
      return "This changed after you approved it, so it was not posted. Look at it again.";
    case "not_approved":
      return "That post has not been approved yet.";
    case "no_media":
      return "There is nothing to publish.";
    case "connection_unhealthy":
      return "That account needs reconnecting.";
    default:
      return "It could not be posted.";
  }
}
