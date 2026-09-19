/**
 * Instagram Reels, through the Instagram API with Instagram Login.
 *
 * Posting is two-step: Instagram fetches the video from a URL into a
 * "container", processes it (seconds to minutes), and only a FINISHED
 * container can be published. The publisher waits a little; whatever is still
 * processing is finished by the scheduler's Verify step, which is why the
 * container id is stored as the target's provider_publish_id.
 *
 * Only Business and Creator accounts can publish through the API.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { accessToken } from "./tiktok.ts";

export const GRAPH = "https://graph.instagram.com/v23.0";
export const INSTAGRAM_SCOPES = ["instagram_business_basic", "instagram_business_content_publish"];

export interface Profile {
  userId: string;
  username: string;
  name: string;
  avatar: string | null;
  accountType: string | null;
}

export async function myProfile(token: string): Promise<Profile | null> {
  const url = new URL(`${GRAPH}/me`);
  url.searchParams.set("fields", "user_id,username,name,profile_picture_url,account_type");
  url.searchParams.set("access_token", token);
  const response = await fetch(url);
  const body = await response.json() as {
    user_id?: string | number; id?: string; username?: string; name?: string;
    profile_picture_url?: string; account_type?: string;
  };
  if (!response.ok || !body.username) return null;
  return {
    userId: String(body.user_id ?? body.id),
    username: body.username,
    name: body.name ?? "",
    avatar: body.profile_picture_url ?? null,
    accountType: body.account_type ?? null,
  };
}

async function igUserId(admin: SupabaseClient, connectionId: string): Promise<string> {
  const { data } = await admin.from("platform_connections").select("provider_user_id").eq("id", connectionId).single();
  return data.provider_user_id as string;
}

export interface ContainerResult { ok: boolean; containerId?: string; code?: string; reason?: string }

/** Step one: Instagram starts fetching the video. */
export async function createReel(
  admin: SupabaseClient,
  connectionId: string,
  input: { videoUrl: string; caption: string; hashtags: string[] },
): Promise<ContainerResult> {
  const token = await accessToken(admin, connectionId);
  const user = await igUserId(admin, connectionId);
  const caption = [input.caption.trim(), input.hashtags.join(" ")].filter(Boolean).join("\n\n").slice(0, 2200);
  const response = await fetch(`${GRAPH}/${user}/media`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      media_type: "REELS",
      video_url: input.videoUrl,
      caption,
      share_to_feed: "true",
      access_token: token,
    }),
  });
  const body = await response.json() as { id?: string; error?: { message?: string; code?: number; error_subcode?: number } };
  if (!response.ok || !body.id) {
    const code = String(body.error?.error_subcode ?? body.error?.code ?? "container_failed");
    return { ok: false, code, reason: plainInstagram(code) ?? body.error?.message ?? "Instagram didn’t accept the video." };
  }
  return { ok: true, containerId: body.id };
}

/** FINISHED, IN_PROGRESS, ERROR, EXPIRED or PUBLISHED. */
export async function containerStatus(
  admin: SupabaseClient,
  connectionId: string,
  containerId: string,
): Promise<{ status: string; detail?: string }> {
  const token = await accessToken(admin, connectionId);
  const url = new URL(`${GRAPH}/${containerId}`);
  url.searchParams.set("fields", "status_code,status");
  url.searchParams.set("access_token", token);
  const response = await fetch(url);
  const body = await response.json() as { status_code?: string; status?: string };
  return { status: body.status_code ?? "IN_PROGRESS", detail: body.status };
}

/** Step two: make a FINISHED container a post. Returns the media id. */
export async function publishReel(
  admin: SupabaseClient,
  connectionId: string,
  containerId: string,
): Promise<{ ok: boolean; mediaId?: string; code?: string; reason?: string }> {
  const token = await accessToken(admin, connectionId);
  const user = await igUserId(admin, connectionId);
  const response = await fetch(`${GRAPH}/${user}/media_publish`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ creation_id: containerId, access_token: token }),
  });
  const body = await response.json() as { id?: string; error?: { message?: string; code?: number; error_subcode?: number } };
  if (!response.ok || !body.id) {
    const code = String(body.error?.error_subcode ?? body.error?.code ?? "publish_failed");
    return { ok: false, code, reason: plainInstagram(code) ?? body.error?.message ?? "Instagram didn’t publish the Reel." };
  }
  return { ok: true, mediaId: body.id };
}

export function plainInstagram(code: string): string | undefined {
  switch (code) {
    case "2207042":
      return "Instagram’s daily posting limit for this account was reached. Pick a time tomorrow.";
    case "2207026":
      return "Instagram couldn’t use this video’s format. Reels need a vertical MP4 or MOV, 3 seconds to 15 minutes.";
    case "190":
      return "Instagram needs you to sign in again (Profile → Accounts).";
    case "10":
    case "200":
      return "This Instagram account can’t publish through apps. It must be a Business or Creator account.";
    default:
      return undefined;
  }
}
