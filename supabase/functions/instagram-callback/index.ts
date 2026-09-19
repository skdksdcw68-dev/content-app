/**
 * Instagram sends the browser here after the person allows access.
 * Exchanges the code for a short-lived token, trades that for the 60-day
 * one, reads who the account is, seals the token, and hands the browser back
 * to the app. Public by necessity; the single-use state stands in for a
 * session.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { claimState, done, FALLBACK_RETURN, recordConnection } from "../_shared/connect.ts";
import { myProfile, INSTAGRAM_SCOPES } from "../_shared/instagram.ts";
import { INSTAGRAM_EARLY_SECONDS } from "../_shared/oauth-refresh.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const APP_ID = Deno.env.get("INSTAGRAM_APP_ID")!;
const APP_SECRET = Deno.env.get("INSTAGRAM_APP_SECRET")!;
const admin = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (request) => {
  const url = new URL(request.url);
  let returnTo = FALLBACK_RETURN;
  try {
    const pending = await claimState(admin, url.searchParams.get("state"));
    if (!pending) return done(returnTo, { status: "error", reason: "expired" });
    returnTo = pending.return_to ?? FALLBACK_RETURN;

    if (url.searchParams.get("error")) return done(returnTo, { status: "denied" });
    // Instagram appends "#_" to the code in some browsers.
    const code = url.searchParams.get("code")?.replace(/#_$/, "");
    if (!code) return done(returnTo, { status: "error", reason: "missing_code" });

    const form = new FormData();
    form.set("client_id", APP_ID);
    form.set("client_secret", APP_SECRET);
    form.set("grant_type", "authorization_code");
    form.set("redirect_uri", `${SUPABASE_URL}/functions/v1/instagram-callback`);
    form.set("code", code);
    const shortResponse = await fetch("https://api.instagram.com/oauth/access_token", { method: "POST", body: form });
    const short = await shortResponse.json() as { access_token?: string; user_id?: number | string; permissions?: string[] | string; error_message?: string };
    if (!shortResponse.ok || !short.access_token) {
      console.error("instagram exchange failed", short.error_message);
      return done(returnTo, { status: "error", reason: "exchange_failed" });
    }

    const longUrl = new URL("https://graph.instagram.com/access_token");
    longUrl.searchParams.set("grant_type", "ig_exchange_token");
    longUrl.searchParams.set("client_secret", APP_SECRET);
    longUrl.searchParams.set("access_token", short.access_token);
    const longResponse = await fetch(longUrl);
    const long = await longResponse.json() as { access_token?: string; expires_in?: number; error?: { message?: string } };
    if (!longResponse.ok || !long.access_token) {
      console.error("instagram long-lived failed", long.error?.message);
      return done(returnTo, { status: "error", reason: "exchange_failed" });
    }

    const profile = await myProfile(long.access_token);
    if (!profile) return done(returnTo, { status: "error", reason: "no_profile" });

    const permissions = Array.isArray(short.permissions)
      ? short.permissions
      : String(short.permissions ?? INSTAGRAM_SCOPES.join(",")).split(",");
    const expires = new Date(
      Date.now() + Math.max(3600, (long.expires_in ?? 5_184_000) - INSTAGRAM_EARLY_SECONDS) * 1000,
    ).toISOString();

    await recordConnection(admin, pending, {
      provider: "instagram",
      providerUserId: profile.userId,
      username: profile.username,
      displayName: profile.name,
      avatar: profile.avatar,
      scopes: permissions.map((p) => p.trim()).filter(Boolean),
    }, {
      access: long.access_token,
      accessExpiresAt: expires,
      // Instagram refreshes the access token itself; kept here too so the
      // refresh column is never empty.
      refresh: long.access_token,
      refreshExpiresAt: expires,
    });

    return done(returnTo, { status: "connected", handle: profile.username });
  } catch (error) {
    console.error("instagram-callback", error);
    return done(returnTo, { status: "error", reason: "server_error" });
  }
});
