/**
 * Reading back what happened.
 *
 * This is where `user.info.stats` and `video.list` earn their place in the scope
 * list: the follower count and the per-video numbers. Without it the app can
 * publish but never learn, and "best hooks" and "best times" have nothing behind
 * them.
 *
 * It writes the numbers onto the posts we published, so a post carries its own
 * result rather than the app having to reconcile two lists every time it draws
 * a screen.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { accessToken } from "../_shared/tiktok.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

interface Video {
  id: string;
  title?: string;
  view_count?: number;
  like_count?: number;
  comment_count?: number;
  share_count?: number;
  create_time?: number;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);

    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const { data: connection } = await asUser
      .from("platform_connections")
      .select("id, username")
      .eq("status", "active")
      .limit(1)
      .maybeSingle();

    if (!connection) throw new PublicError("No account is connected.", 404);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const token = await accessToken(admin, connection.id);

    // --- the account itself: user.info.stats --------------------------------

    const profileResponse = await fetch(
      "https://open.tiktokapis.com/v2/user/info/?fields=open_id,follower_count,following_count,likes_count,video_count",
      { headers: { Authorization: `Bearer ${token}` } },
    );
    const profile = await profileResponse.json() as {
      data?: { user?: { follower_count?: number; likes_count?: number; video_count?: number } };
      error?: { code?: string; message?: string };
    };

    const user = profile.data?.user;

    // --- the videos: video.list --------------------------------------------

    const listResponse = await fetch(
      "https://open.tiktokapis.com/v2/video/list/?fields=id,title,view_count,like_count,comment_count,share_count,create_time",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json; charset=UTF-8",
        },
        body: JSON.stringify({ max_count: 20 }),
      },
    );
    const listed = await listResponse.json() as {
      data?: { videos?: Video[] };
      error?: { code?: string; message?: string };
    };

    const videos = listed.data?.videos ?? [];

    // Attach each video's numbers to the post that produced it, where we know
    // the id. Posts published before this existed simply have no match, which
    // is not an error.
    let matched = 0;
    if (videos.length > 0) {
      const { data: published } = await admin
        .from("post_targets")
        .select("id, provider_post_id")
        .eq("connection_id", connection.id)
        .eq("state", "published");

      for (const target of published ?? []) {
        const video = videos.find((v) => v.id === target.provider_post_id);
        if (!video) continue;

        await admin.from("post_targets").update({
          metrics: {
            views: video.view_count ?? 0,
            likes: video.like_count ?? 0,
            comments: video.comment_count ?? 0,
            shares: video.share_count ?? 0,
          },
          metrics_at: new Date().toISOString(),
        }).eq("id", target.id);

        matched += 1;
      }
    }

    const totals = videos.reduce(
      (sum, v) => ({
        views: sum.views + (v.view_count ?? 0),
        likes: sum.likes + (v.like_count ?? 0),
        comments: sum.comments + (v.comment_count ?? 0),
        shares: sum.shares + (v.share_count ?? 0),
      }),
      { views: 0, likes: 0, comments: 0, shares: 0 },
    );

    return json({
      username: connection.username,
      // Nulls rather than zeros when the platform did not answer. "Not
      // reported" and "nobody did it" are different facts and the tiles show
      // them differently.
      followers: user?.follower_count ?? null,
      total_likes: user?.likes_count ?? null,
      video_count: user?.video_count ?? null,
      recent: videos.slice(0, 10).map((v) => ({
        id: v.id,
        title: v.title ?? "",
        views: v.view_count ?? 0,
        likes: v.like_count ?? 0,
        comments: v.comment_count ?? 0,
        shares: v.share_count ?? 0,
      })),
      totals,
      matched_to_our_posts: matched,
      errors: [profile.error?.message, listed.error?.message].filter(
        (message) => message && message !== "ok",
      ),
    });
  } catch (error) {
    return fail(error);
  }
});
