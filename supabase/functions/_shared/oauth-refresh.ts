/**
 * Refreshing YouTube and Instagram tokens. TikTok's own refresh stays in
 * tiktok.ts; `accessToken()` there picks the right one by the connection's
 * provider, so every caller keeps asking one function for a usable token.
 *
 * Both write back through store_platform_credential, sealed with the row's
 * AAD exactly like TikTok's.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { seal, open, keyVersion } from "./crypto.ts";
import { PublicError } from "./http.ts";

const GOOGLE_CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID") ?? "";
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET") ?? "";

/** Instagram tokens live 60 days and can only be refreshed while still
 *  valid, so the stored expiry is set a week early: the ordinary
 *  "refresh when close to expiry" check then refreshes a live token. */
export const INSTAGRAM_EARLY_SECONDS = 7 * 86_400;

interface Stored { access_ct: string; refresh_ct: string }

async function unhealthy(admin: SupabaseClient, connectionId: string, detail: string): Promise<never> {
  await admin.rpc("mark_connection_unhealthy", {
    p_connection_id: connectionId, p_status: "expired", p_error: detail,
  });
  throw new PublicError("That account needs reconnecting.", 409);
}

export async function refreshYouTube(admin: SupabaseClient, connectionId: string, credential: Stored): Promise<string> {
  const refreshToken = await open(credential.refresh_ct, `${connectionId}:refresh`);
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      grant_type: "refresh_token",
      refresh_token: refreshToken,
    }),
  });
  const token = await response.json() as { access_token?: string; expires_in?: number; error?: string; error_description?: string };
  if (!response.ok || !token.access_token) {
    // While the Google app is in Testing, refresh tokens die after 7 days.
    return await unhealthy(admin, connectionId, token.error_description ?? token.error ?? "Google refused the refresh.");
  }
  await admin.rpc("store_platform_credential", {
    p_connection_id: connectionId,
    p_key_version: keyVersion,
    p_access_ct: await seal(token.access_token, `${connectionId}:access`),
    p_access_expires_at: new Date(Date.now() + (token.expires_in ?? 3600) * 1000).toISOString(),
    // Google keeps the same refresh token.
    p_refresh_ct: credential.refresh_ct,
    p_refresh_expires_at: null,
  });
  return token.access_token;
}

export async function refreshInstagram(admin: SupabaseClient, connectionId: string, credential: Stored): Promise<string> {
  const current = await open(credential.access_ct, `${connectionId}:access`);
  const url = new URL("https://graph.instagram.com/refresh_access_token");
  url.searchParams.set("grant_type", "ig_refresh_token");
  url.searchParams.set("access_token", current);
  const response = await fetch(url);
  const token = await response.json() as { access_token?: string; expires_in?: number; error?: { message?: string } };
  if (!response.ok || !token.access_token) {
    return await unhealthy(admin, connectionId, token.error?.message ?? "Instagram refused the refresh.");
  }
  const sealed = await seal(token.access_token, `${connectionId}:access`);
  const expires = new Date(Date.now() + Math.max(3600, (token.expires_in ?? 5_184_000) - INSTAGRAM_EARLY_SECONDS) * 1000).toISOString();
  await admin.rpc("store_platform_credential", {
    p_connection_id: connectionId,
    p_key_version: keyVersion,
    p_access_ct: sealed,
    p_access_expires_at: expires,
    p_refresh_ct: await seal(token.access_token, `${connectionId}:refresh`),
    p_refresh_expires_at: expires,
  });
  return token.access_token;
}
