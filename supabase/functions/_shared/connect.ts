/**
 * What every platform's OAuth callback shares: claiming the single-use
 * state, sending the browser back to the app with a result, and recording
 * the connection with its tokens sealed. TikTok's callback predates this and
 * keeps its own copy; YouTube and Instagram use this one.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { redirect } from "./http.ts";
import { seal, keyVersion } from "./crypto.ts";

export const FALLBACK_RETURN = "autocast://oauth/done";

export function done(returnTo: string, params: Record<string, string>): Response {
  const url = new URL(returnTo);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  return redirect(url.toString());
}

export interface Pending {
  user_id: string;
  brand_id: string;
  platform: string;
  return_to: string | null;
  expires_at: string;
}

/** Consumed on read, so a replayed redirect finds nothing. */
export async function claimState(admin: SupabaseClient, state: string | null): Promise<Pending | null> {
  if (!state) return null;
  const { data } = await admin
    .from("oauth_states")
    .delete()
    .eq("state", state)
    .select("user_id, brand_id, platform, return_to, expires_at")
    .maybeSingle();
  if (!data || new Date(data.expires_at).getTime() < Date.now()) return null;
  return data as Pending;
}

export async function recordConnection(
  admin: SupabaseClient,
  pending: Pending,
  account: {
    provider: string;
    providerUserId: string;
    username: string;
    displayName: string;
    avatar: string | null;
    scopes: string[];
  },
  tokens: { access: string; accessExpiresAt: string; refresh: string; refreshExpiresAt: string | null },
): Promise<void> {
  const { data: connection, error } = await admin
    .from("platform_connections")
    .upsert(
      {
        user_id: pending.user_id,
        brand_id: pending.brand_id,
        platform: pending.platform,
        provider: account.provider,
        provider_user_id: account.providerUserId,
        username: account.username,
        display_name: account.displayName,
        avatar_url: account.avatar,
        avatar_fetched_at: account.avatar ? new Date().toISOString() : null,
        scopes: account.scopes,
        status: "active",
        connected_at: new Date().toISOString(),
        revoked_at: null,
        last_error: null,
      },
      { onConflict: "brand_id,platform,provider_user_id" },
    )
    .select("id")
    .single();
  if (error || !connection) throw error ?? new Error("no connection row");

  const { error: storeError } = await admin.rpc("store_platform_credential", {
    p_connection_id: connection.id,
    p_key_version: keyVersion,
    p_access_ct: await seal(tokens.access, `${connection.id}:access`),
    p_access_expires_at: tokens.accessExpiresAt,
    p_refresh_ct: await seal(tokens.refresh, `${connection.id}:refresh`),
    p_refresh_expires_at: tokens.refreshExpiresAt,
  });
  if (storeError) throw storeError;

  // The publisher skips any connection without a rate row.
  await admin.from("account_rate_state").upsert({ connection_id: connection.id }, { onConflict: "connection_id" });
}
