/**
 * Begins connecting a social account.
 *
 * The app calls this with a brand and a platform, gets back a URL, and opens it
 * in a browser sheet. Everything secret stays here: the app never sees the
 * client secret, and never handles a token.
 *
 * Called with the person's own JWT, so the brand is proved to be theirs by RLS
 * rather than by trusting the request body.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError, CORS } from "../_shared/http.ts";
import { randomToken } from "../_shared/crypto.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const TIKTOK_CLIENT_KEY = Deno.env.get("TIKTOK_CLIENT_KEY");
const REDIRECT_URI =
  Deno.env.get("TIKTOK_REDIRECT_URI") ?? "https://netrocast.com/oauth/tiktok/callback/";

/**
 * Everything the product needs, asked for once.
 *
 * Adding a scope later means another review round and another consent screen,
 * so the list is the whole product rather than the current milestone.
 *
 *   user.info.basic    open_id, display_name, avatar_url -- shown on the
 *                      approval screen so a person always sees which account
 *                      a post will publish from
 *   user.info.profile  username. basic does not return it, and two connected
 *                      accounts are indistinguishable without it
 *   user.info.stats    follower count, for Insights
 *   video.list         view, like, comment and share counts for posts we
 *                      published. This is the feedback loop: without it
 *                      post_targets.metrics is never filled, and "best hooks"
 *                      and "best posting times" have nothing behind them
 *   video.upload       put a post in the person's drafts to finish themselves
 *   video.publish      direct post, once the audit clears
 */
const TIKTOK_SCOPES = [
  "user.info.basic",
  "user.info.profile",
  "user.info.stats",
  "video.list",
  "video.upload",
  "video.publish",
];

interface StartBody {
  brand_id?: string;
  platform?: string;
  return_to?: string;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") {
    return json({ error: "POST only" }, 405);
  }

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);

    // Scoped to the caller: RLS decides which brands exist as far as this
    // client is concerned, so a forged brand_id simply finds nothing.
    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });

    const { data: auth, error: authError } = await asUser.auth.getUser();
    if (authError || !auth.user) throw new PublicError("Sign in first.", 401);

    const body = (await request.json().catch(() => ({}))) as StartBody;
    const platform = body.platform ?? "tiktok";
    if (platform !== "tiktok") {
      throw new PublicError(`${platform} is not connectable yet.`);
    }
    if (!TIKTOK_CLIENT_KEY) {
      throw new PublicError("TikTok is not configured on this deployment.", 503);
    }
    if (!body.brand_id) throw new PublicError("brand_id is required.");

    const { data: brand } = await asUser
      .from("brands")
      .select("id")
      .eq("id", body.brand_id)
      .maybeSingle();
    if (!brand) throw new PublicError("That brand does not exist.", 404);

    // Opaque, single-use, and short-lived. This is the only thing tying the
    // browser that comes back to the person who started the flow -- nothing in
    // the redirect is trusted beyond this handle.
    const state = randomToken(32);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { error: stateError } = await admin.from("oauth_states").insert({
      state,
      user_id: auth.user.id,
      brand_id: body.brand_id,
      platform,
      return_to: body.return_to ?? "autocast://oauth/done",
    });
    if (stateError) throw stateError;

    const authorize = new URL("https://www.tiktok.com/v2/auth/authorize/");
    authorize.searchParams.set("client_key", TIKTOK_CLIENT_KEY);
    authorize.searchParams.set("scope", TIKTOK_SCOPES.join(","));
    authorize.searchParams.set("response_type", "code");
    authorize.searchParams.set("redirect_uri", REDIRECT_URI);
    authorize.searchParams.set("state", state);

    return json({ authorize_url: authorize.toString(), state });
  } catch (error) {
    return fail(error);
  }
});
