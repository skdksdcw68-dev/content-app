/**
 * The other half of connecting an account.
 *
 * TikTok sends the browser to netrocast.com, which forwards here with the code
 * and state. This exchanges the code, records who was connected, seals the
 * tokens, and hands the browser back to the app.
 *
 * Public by necessity -- a browser redirect carries no Supabase session. What
 * stands in for a JWT is the `state` handle: single-use, ten-minute lifetime,
 * and the only thing in the request that is believed.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { redirect } from "../_shared/http.ts";
import { seal, keyVersion } from "../_shared/crypto.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const TIKTOK_CLIENT_KEY = Deno.env.get("TIKTOK_CLIENT_KEY")!;
const TIKTOK_CLIENT_SECRET = Deno.env.get("TIKTOK_CLIENT_SECRET")!;
const REDIRECT_URI =
  Deno.env.get("TIKTOK_REDIRECT_URI") ?? "https://netrocast.com/oauth/tiktok/callback/";

const FALLBACK_RETURN = "autocast://oauth/done";

interface TokenResponse {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
  refresh_expires_in?: number;
  open_id?: string;
  scope?: string;
  error?: string;
  error_description?: string;
}

interface UserInfoResponse {
  data?: { user?: { open_id?: string; username?: string; display_name?: string; avatar_url?: string } };
  error?: { code?: string; message?: string };
}

/** Sends the browser back to the app with a result it can act on. */
function done(returnTo: string, params: Record<string, string>): Response {
  const url = new URL(returnTo);
  for (const [key, value] of Object.entries(params)) {
    url.searchParams.set(key, value);
  }
  return redirect(url.toString());
}

Deno.serve(async (request) => {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const deniedReason = url.searchParams.get("error");

  // Resolved as early as possible so every failure below can still land the
  // person back in the app rather than on a blank page.
  let returnTo = FALLBACK_RETURN;

  try {
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    if (!state) return done(returnTo, { status: "error", reason: "missing_state" });

    // Consumed on read: claiming the row and deleting it in one step is what
    // makes a replayed redirect harmless.
    const { data: pending } = await admin
      .from("oauth_states")
      .delete()
      .eq("state", state)
      .select("user_id, brand_id, platform, return_to, expires_at")
      .maybeSingle();

    if (!pending) return done(returnTo, { status: "error", reason: "unknown_state" });
    returnTo = pending.return_to ?? FALLBACK_RETURN;

    if (new Date(pending.expires_at).getTime() < Date.now()) {
      return done(returnTo, { status: "error", reason: "expired" });
    }

    // The person pressed Cancel on TikTok's screen. Not an error worth logging.
    if (deniedReason) {
      return done(returnTo, { status: "denied", reason: deniedReason });
    }
    if (!code) return done(returnTo, { status: "error", reason: "missing_code" });

    // --- exchange -----------------------------------------------------------

    const tokenResponse = await fetch("https://open.tiktokapis.com/v2/oauth/token/", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_key: TIKTOK_CLIENT_KEY,
        client_secret: TIKTOK_CLIENT_SECRET,
        code,
        grant_type: "authorization_code",
        redirect_uri: REDIRECT_URI,
      }),
    });

    const token = (await tokenResponse.json()) as TokenResponse;
    if (!tokenResponse.ok || token.error || !token.access_token || !token.open_id) {
      console.error("token exchange failed", token.error, token.error_description);
      return done(returnTo, { status: "error", reason: "exchange_failed" });
    }

    // --- who did we just connect --------------------------------------------

    // Fetched now rather than at publish time: the platform requires the
    // creator be identified before a post goes out, and the approval screen is
    // what has to show them.
    const infoResponse = await fetch(
      "https://open.tiktokapis.com/v2/user/info/?fields=open_id,username,display_name,avatar_url",
      { headers: { Authorization: `Bearer ${token.access_token}` } },
    );
    const info = (await infoResponse.json()) as UserInfoResponse;
    const profile = info.data?.user;

    if (!infoResponse.ok || (info.error?.code !== undefined && info.error.code !== "ok")) {
      // Not fatal: the connection is real even if the profile fetch hiccuped.
      // The publisher re-reads creator info before every post anyway.
      console.error("user info failed", info.error);
    }

    // --- record it ----------------------------------------------------------

    const { data: connection, error: connectionError } = await admin
      .from("platform_connections")
      .upsert(
        {
          user_id: pending.user_id,
          brand_id: pending.brand_id,
          platform: pending.platform,
          provider: "tiktok_direct",
          provider_user_id: token.open_id,
          username: profile?.username ?? profile?.display_name ?? "unknown",
          display_name: profile?.display_name ?? "",
          avatar_url: profile?.avatar_url ?? null,
          avatar_fetched_at: profile?.avatar_url ? new Date().toISOString() : null,
          scopes: (token.scope ?? "").split(",").filter(Boolean),
          status: "active",
          revoked_at: null,
          last_error: null,
        },
        { onConflict: "brand_id,platform,provider_user_id" },
      )
      .select("id")
      .single();

    if (connectionError || !connection) throw connectionError ?? new Error("no connection row");

    const now = Date.now();
    const accessExpiry = new Date(now + (token.expires_in ?? 86_400) * 1000).toISOString();
    const refreshExpiry = new Date(
      now + (token.refresh_expires_in ?? 365 * 86_400) * 1000,
    ).toISOString();

    // Bound to the row by AAD, so this ciphertext is meaningless anywhere else.
    const accessCt = await seal(token.access_token, `${connection.id}:access`);
    const refreshCt = await seal(token.refresh_token ?? "", `${connection.id}:refresh`);

    const { error: storeError } = await admin.rpc("store_platform_credential", {
      p_connection_id: connection.id,
      p_key_version: keyVersion,
      p_access_ct: accessCt,
      p_access_expires_at: accessExpiry,
      p_refresh_ct: refreshCt,
      p_refresh_expires_at: refreshExpiry,
    });
    if (storeError) throw storeError;

    // A fresh account has no rate state, and the publisher's claim skips any
    // connection without one -- so a missing row here is a post that silently
    // never goes out.
    await admin
      .from("account_rate_state")
      .upsert({ connection_id: connection.id }, { onConflict: "connection_id" });

    return done(returnTo, {
      status: "connected",
      handle: profile?.username ?? profile?.display_name ?? "",
    });
  } catch (error) {
    console.error("oauth-callback", error);
    return done(returnTo, { status: "error", reason: "server_error" });
  }
});
