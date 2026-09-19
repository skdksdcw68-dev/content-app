/**
 * YouTube Shorts: who the channel is, and uploading a video to it.
 *
 * A vertical video of three minutes or less is a Short on its own; there is
 * no separate Shorts endpoint. Until Google has audited the API project,
 * every upload is locked to private by YouTube -- the same shape as TikTok's
 * review, and said to the person rather than discovered.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { accessToken } from "./tiktok.ts";

export const YOUTUBE_SCOPES = [
  "https://www.googleapis.com/auth/youtube.upload",
  "https://www.googleapis.com/auth/youtube.readonly",
];

export interface Channel {
  id: string;
  title: string;
  handle: string;
  avatar: string | null;
}

export async function myChannel(token: string): Promise<Channel | null> {
  const response = await fetch("https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true", {
    headers: { Authorization: `Bearer ${token}` },
  });
  const body = await response.json() as {
    items?: Array<{ id: string; snippet?: { title?: string; customUrl?: string; thumbnails?: { default?: { url?: string } } } }>;
  };
  const item = body.items?.[0];
  if (!item) return null;
  return {
    id: item.id,
    title: item.snippet?.title ?? "",
    handle: (item.snippet?.customUrl ?? item.snippet?.title ?? "channel").replace(/^@/, ""),
    avatar: item.snippet?.thumbnails?.default?.url ?? null,
  };
}

/** Autocast's visibility words, in YouTube's. */
export function youtubePrivacy(privacy: string): "public" | "unlisted" | "private" {
  if (privacy === "PUBLIC_TO_EVERYONE") return "public";
  if (privacy === "SELF_ONLY") return "private";
  return "unlisted";
}

export interface UploadResult {
  ok: boolean;
  videoId?: string;
  reason?: string;
  code?: string;
}

export async function uploadShort(
  admin: SupabaseClient,
  connectionId: string,
  input: { bytes: Uint8Array; mime: string; caption: string; hashtags: string[]; privacy: string; isAIGC: boolean },
): Promise<UploadResult> {
  const token = await accessToken(admin, connectionId);

  // The title is the first line; the description is everything, with the
  // hashtags YouTube uses (#Shorts helps it file the video correctly).
  const firstLine = input.caption.split("\n").map((l) => l.trim()).find(Boolean) ?? "New video";
  const title = firstLine.replace(/(^|\s)#\w+/g, "").trim().slice(0, 100) || "New video";
  const tags = [...new Set([...input.hashtags, "#Shorts"])];
  const description = [input.caption.trim(), tags.join(" ")].filter(Boolean).join("\n\n").slice(0, 4900);

  const start = await fetch(
    "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json; charset=UTF-8",
        "X-Upload-Content-Length": String(input.bytes.byteLength),
        "X-Upload-Content-Type": input.mime || "video/mp4",
      },
      body: JSON.stringify({
        snippet: {
          title,
          description,
          tags: tags.map((t) => t.replace(/^#/, "")).slice(0, 30),
          categoryId: "22",
        },
        status: {
          privacyStatus: youtubePrivacy(input.privacy),
          selfDeclaredMadeForKids: false,
          containsSyntheticMedia: input.isAIGC,
        },
      }),
    },
  );
  const location = start.headers.get("Location");
  if (!start.ok || !location) {
    const body = await start.json().catch(() => ({})) as { error?: { message?: string; errors?: Array<{ reason?: string }> } };
    const code = body.error?.errors?.[0]?.reason ?? "upload_start_failed";
    return { ok: false, code, reason: plainYouTube(code) ?? body.error?.message ?? "YouTube didn’t accept the upload." };
  }

  const put = await fetch(location, {
    method: "PUT",
    headers: { "Content-Type": input.mime || "video/mp4", "Content-Length": String(input.bytes.byteLength) },
    body: input.bytes,
  });
  const result = await put.json().catch(() => ({})) as {
    id?: string; status?: { uploadStatus?: string; rejectionReason?: string; failureReason?: string };
    error?: { message?: string; errors?: Array<{ reason?: string }> };
  };
  if (!put.ok || !result.id) {
    const code = result.error?.errors?.[0]?.reason ?? "upload_failed";
    return { ok: false, code, reason: plainYouTube(code) ?? result.error?.message ?? "The upload to YouTube failed." };
  }
  if (result.status?.uploadStatus === "rejected" || result.status?.uploadStatus === "failed") {
    const why = result.status.rejectionReason ?? result.status.failureReason ?? "rejected";
    return { ok: false, code: why, reason: `YouTube rejected the video (${why}).` };
  }
  return { ok: true, videoId: result.id };
}

export function plainYouTube(code: string): string | undefined {
  switch (code) {
    case "quotaExceeded":
      return "YouTube’s daily upload allowance for Autocast is used up. It resets at midnight Pacific time.";
    case "uploadLimitExceeded":
      return "This channel has reached YouTube’s upload limit for now. Try again later.";
    case "youtubeSignupRequired":
      return "This Google account has no YouTube channel yet. Create one on YouTube, then connect again.";
    case "authError":
    case "unauthorized":
      return "YouTube needs you to sign in again (Profile → Accounts).";
    default:
      return undefined;
  }
}
