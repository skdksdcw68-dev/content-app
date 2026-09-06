/**
 * Talking to TikTok as a creator.
 *
 * Everything here needs a decrypted access token, so it all runs server-side and
 * none of it is reachable from the app. The app asks for the *result* -- what
 * privacy levels this account currently offers -- and never for the token.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { seal, open, keyVersion } from "./crypto.ts";
import { PublicError } from "./http.ts";

const CLIENT_KEY = Deno.env.get("TIKTOK_CLIENT_KEY")!;
const CLIENT_SECRET = Deno.env.get("TIKTOK_CLIENT_SECRET")!;

/** Refresh this far ahead of expiry rather than at it, so a slow request in
 *  flight does not land after the token has died. */
const REFRESH_MARGIN_MS = 10 * 60 * 1000;

interface StoredCredential {
  key_version: number;
  access_ct: string;
  access_expires_at: string;
  refresh_ct: string;
  refresh_expires_at: string | null;
  refresh_lock: string | null;
}

interface TokenResponse {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
  refresh_expires_in?: number;
  error?: string;
  error_description?: string;
}

/**
 * Returns a usable access token, refreshing first if it is close to expiring.
 *
 * The refresh is single-flight: whoever wins `claim_credential_refresh` does it,
 * and everyone else waits and re-reads. Without that, two concurrent refreshes
 * race and the loser ends up holding a refresh token TikTok has already
 * invalidated -- a connection that is dead with nothing to show for it.
 */
export async function accessToken(
  admin: SupabaseClient,
  connectionId: string,
): Promise<string> {
  const credential = await readCredential(admin, connectionId);

  const expiresAt = new Date(credential.access_expires_at).getTime();
  if (expiresAt - Date.now() > REFRESH_MARGIN_MS) {
    return await open(credential.access_ct, `${connectionId}:access`);
  }

  const { data: claimed } = await admin.rpc("claim_credential_refresh", {
    p_connection_id: connectionId,
  });

  if (claimed !== true) {
    // Somebody else is refreshing. Give them a moment, then use whatever they
    // committed rather than starting a second refresh and killing both.
    await new Promise((resolve) => setTimeout(resolve, 1_500));
    const fresh = await readCredential(admin, connectionId);
    return await open(fresh.access_ct, `${connectionId}:access`);
  }

  return await refresh(admin, connectionId, credential);
}

async function readCredential(
  admin: SupabaseClient,
  connectionId: string,
): Promise<StoredCredential> {
  const { data, error } = await admin.rpc("read_platform_credential", {
    p_connection_id: connectionId,
  });
  if (error) throw error;

  const row = (data as StoredCredential[] | null)?.[0];
  if (!row) throw new PublicError("That account is no longer connected.", 409);
  return row;
}

async function refresh(
  admin: SupabaseClient,
  connectionId: string,
  credential: StoredCredential,
): Promise<string> {
  const refreshToken = await open(credential.refresh_ct, `${connectionId}:refresh`);

  const response = await fetch("https://open.tiktokapis.com/v2/oauth/token/", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_key: CLIENT_KEY,
      client_secret: CLIENT_SECRET,
      grant_type: "refresh_token",
      refresh_token: refreshToken,
    }),
  });

  const token = (await response.json()) as TokenResponse;

  if (!response.ok || token.error || !token.access_token) {
    // The refresh token is gone: revoked on TikTok, or expired after a year of
    // no use. Record it so the app can say "reconnect" rather than failing on
    // every post from here on with no explanation.
    await admin.rpc("mark_connection_unhealthy", {
      p_connection_id: connectionId,
      p_status: "expired",
      p_error: token.error_description ?? token.error ?? "Refresh was rejected.",
    });
    throw new PublicError("That account needs reconnecting.", 409);
  }

  const now = Date.now();

  // TikTok returns a new refresh token and invalidates the old one. Storing the
  // returned value is not optional -- reusing the one we sent would fail next
  // time, silently, a day later.
  await admin.rpc("store_platform_credential", {
    p_connection_id: connectionId,
    p_key_version: keyVersion,
    p_access_ct: await seal(token.access_token, `${connectionId}:access`),
    p_access_expires_at: new Date(now + (token.expires_in ?? 86_400) * 1000).toISOString(),
    p_refresh_ct: await seal(
      token.refresh_token ?? refreshToken,
      `${connectionId}:refresh`,
    ),
    p_refresh_expires_at: new Date(
      now + (token.refresh_expires_in ?? 365 * 86_400) * 1000,
    ).toISOString(),
  });

  return token.access_token;
}

// ------------------------------------------------------------------ creator

export interface CreatorInfo {
  creator_avatar_url: string;
  creator_username: string;
  creator_nickname: string;
  privacy_level_options: string[];
  comment_disabled: boolean;
  duet_disabled: boolean;
  stitch_disabled: boolean;
  max_video_post_duration_sec: number;
}

/**
 * What this account currently allows.
 *
 * Read immediately before showing the approval screen, and again immediately
 * before publishing. It is not cached for a day: a creator who switches their
 * account to private between approving and posting must not have a post go out
 * publicly because we were working from yesterday's answer.
 */
export async function creatorInfo(
  admin: SupabaseClient,
  connectionId: string,
): Promise<CreatorInfo> {
  const token = await accessToken(admin, connectionId);

  const response = await fetch(
    "https://open.tiktokapis.com/v2/post/publish/creator_info/query/",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json; charset=UTF-8",
      },
    },
  );

  const body = (await response.json()) as {
    data?: CreatorInfo;
    error?: { code?: string; message?: string };
  };

  if (!response.ok || !body.data) {
    const code = body.error?.code ?? "unknown";
    if (code === "access_token_invalid" || code === "scope_not_authorized") {
      await admin.rpc("mark_connection_unhealthy", {
        p_connection_id: connectionId,
        p_status: "error",
        p_error: body.error?.message ?? code,
      });
    }
    throw new PublicError(
      body.error?.message ?? "TikTok would not say what this account allows.",
      502,
    );
  }

  return body.data;
}
