/**
 * Google sends the browser here after the person allows YouTube access.
 * Exchanges the code, finds their channel, seals the tokens, and hands the
 * browser back to the app. Public by necessity (a redirect carries no
 * session); the single-use state stands in for one.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { claimState, done, FALLBACK_RETURN, recordConnection } from "../_shared/connect.ts";
import { myChannel, YOUTUBE_SCOPES } from "../_shared/youtube.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (request) => {
  const url = new URL(request.url);
  let returnTo = FALLBACK_RETURN;
  try {
    const pending = await claimState(admin, url.searchParams.get("state"));
    if (!pending) return done(returnTo, { status: "error", reason: "expired" });
    returnTo = pending.return_to ?? FALLBACK_RETURN;

    if (url.searchParams.get("error")) return done(returnTo, { status: "denied" });
    const code = url.searchParams.get("code");
    if (!code) return done(returnTo, { status: "error", reason: "missing_code" });

    const response = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: Deno.env.get("GOOGLE_CLIENT_ID")!,
        client_secret: Deno.env.get("GOOGLE_CLIENT_SECRET")!,
        code,
        grant_type: "authorization_code",
        redirect_uri: `${SUPABASE_URL}/functions/v1/youtube-callback`,
      }),
    });
    const token = await response.json() as {
      access_token?: string; refresh_token?: string; expires_in?: number; scope?: string; error?: string; error_description?: string;
    };
    if (!response.ok || !token.access_token) {
      console.error("google exchange failed", token.error, token.error_description);
      return done(returnTo, { status: "error", reason: "exchange_failed" });
    }
    if (!token.refresh_token) {
      // Without one the connection would die within the hour.
      return done(returnTo, { status: "error", reason: "no_refresh_token" });
    }
    const granted = (token.scope ?? "").split(" ");
    if (!granted.includes(YOUTUBE_SCOPES[0])) {
      return done(returnTo, { status: "error", reason: "upload_not_allowed" });
    }

    const channel = await myChannel(token.access_token);
    if (!channel) return done(returnTo, { status: "error", reason: "no_channel" });

    await recordConnection(admin, pending, {
      provider: "youtube",
      providerUserId: channel.id,
      username: channel.handle,
      displayName: channel.title,
      avatar: channel.avatar,
      scopes: granted,
    }, {
      access: token.access_token,
      accessExpiresAt: new Date(Date.now() + (token.expires_in ?? 3600) * 1000).toISOString(),
      refresh: token.refresh_token,
      refreshExpiresAt: null,
    });

    return done(returnTo, { status: "connected", handle: channel.handle });
  } catch (error) {
    console.error("youtube-callback", error);
    return done(returnTo, { status: "error", reason: "server_error" });
  }
});
