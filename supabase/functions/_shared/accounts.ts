/**
 * What a connected account allows, for any platform, in TikTok's shape --
 * the shape the approval screen, approve-post and the publisher already
 * speak. TikTok answers live (creator_info); YouTube and Instagram have no
 * such call, so their answer is the platform's fixed rules plus who the
 * account is.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { creatorInfo, type CreatorInfo } from "./tiktok.ts";

export async function accountOptions(admin: SupabaseClient, connectionId: string): Promise<CreatorInfo> {
  const { data: connection } = await admin
    .from("platform_connections")
    .select("platform, username, display_name, avatar_url")
    .eq("id", connectionId)
    .single();

  if (connection.platform === "shorts") {
    return {
      creator_avatar_url: connection.avatar_url ?? "",
      creator_username: connection.username,
      creator_nickname: connection.display_name ?? "",
      // Public, unlisted or private. Unlisted rides on FOLLOWER_OF_CREATOR in
      // the shared vocabulary (youtubePrivacy maps it back); the app labels
      // it "Unlisted" for YouTube.
      privacy_level_options: ["PUBLIC_TO_EVERYONE", "FOLLOWER_OF_CREATOR", "SELF_ONLY"],
      comment_disabled: false,
      duet_disabled: true,
      stitch_disabled: true,
      // A Short is three minutes or less.
      max_video_post_duration_sec: 180,
    };
  }

  if (connection.platform === "reels") {
    return {
      creator_avatar_url: connection.avatar_url ?? "",
      creator_username: connection.username,
      creator_nickname: connection.display_name ?? "",
      // A Reel goes to the account's audience; Instagram has no per-post choice.
      privacy_level_options: ["PUBLIC_TO_EVERYONE"],
      comment_disabled: false,
      duet_disabled: true,
      stitch_disabled: true,
      max_video_post_duration_sec: 900,
    };
  }

  return await creatorInfo(admin, connectionId);
}
