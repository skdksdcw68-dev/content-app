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
 * a screen -- and it APPENDS every reading to the snapshot tables (0037), with
 * each video's cover, length and caption (0039), because a chart needs
 * yesterday's number as well as today's.
 *
 * After reading, it relearns (`_shared/learning.ts`): the loop from a post's
 * numbers to what Autocast recommends next runs every time numbers arrive.
 *
 * Two ways in:
 *   - the phone, with a session, for one connection (the brand on screen);
 *   - the database, every six hours, with `x-cron-secret`, for all of them.
 */

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { accessToken } from "../_shared/tiktok.ts";
import { learn } from "../_shared/learning.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");

/** Everything video.list will give an app, and nothing it will not. */
const VIDEO_FIELDS = "id,title,video_description,duration,cover_image_url,share_url,view_count,like_count,comment_count,share_count,create_time";

interface Video {
  id: string;
  title?: string;
  video_description?: string;
  duration?: number;
  cover_image_url?: string;
  share_url?: string;
  view_count?: number;
  like_count?: number;
  comment_count?: number;
  share_count?: number;
  create_time?: number;
}

interface Connection {
  id: string;
  user_id: string;
  brand_id: string | null;
  username: string;
  platform: string;
}

/** Constant-time, so the secret cannot be found a character at a time. */
function sameSecret(given: string, expected: string): boolean {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return diff === 0;
}

/** Every page of video.list, up to a cap. One page of 20 was the old limit, and
 *  an account's 21st video simply never had a history. */
async function listVideos(token: string): Promise<{ videos: Video[]; error?: string }> {
  const videos: Video[] = [];
  let cursor: number | undefined;
  for (let page = 0; page < 5; page++) {
    const response = await fetch(`https://open.tiktokapis.com/v2/video/list/?fields=${VIDEO_FIELDS}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json; charset=UTF-8",
      },
      body: JSON.stringify(cursor ? { max_count: 20, cursor } : { max_count: 20 }),
    });
    const listed = await response.json() as {
      data?: { videos?: Video[]; cursor?: number; has_more?: boolean };
      error?: { code?: string; message?: string };
    };
    if (listed.error?.code && listed.error.code !== "ok") {
      return { videos, error: listed.error.message ?? listed.error.code };
    }
    videos.push(...(listed.data?.videos ?? []));
    if (!listed.data?.has_more || !listed.data.cursor) break;
    cursor = listed.data.cursor;
  }
  return { videos };
}

async function measure(admin: SupabaseClient, connection: Connection) {
  const token = await accessToken(admin, connection.id);

  // --- the account itself: user.info.stats ----------------------------------

  const profileResponse = await fetch(
    "https://open.tiktokapis.com/v2/user/info/?fields=open_id,follower_count,following_count,likes_count,video_count",
    { headers: { Authorization: `Bearer ${token}` } },
  );
  const profile = await profileResponse.json() as {
    data?: { user?: { follower_count?: number; likes_count?: number; video_count?: number } };
    error?: { code?: string; message?: string };
  };

  const user = profile.data?.user;

  // --- the videos: video.list ------------------------------------------------

  const listed = await listVideos(token);
  const videos = listed.videos;
  const now = new Date().toISOString();

  // Which of these videos we posted, by the platform's id. Posts published
  // before this existed simply have no match, which is not an error.
  const { data: published } = await admin
    .from("post_targets")
    .select("id, provider_post_id")
    .eq("connection_id", connection.id)
    .eq("state", "published");

  const targetFor = new Map<string, string>();
  for (const target of published ?? []) {
    if (target.provider_post_id) targetFor.set(target.provider_post_id, target.id);
  }

  let matched = 0;
  for (const video of videos) {
    const target = targetFor.get(video.id);
    if (!target) continue;

    await admin.from("post_targets").update({
      metrics: {
        views: video.view_count ?? 0,
        likes: video.like_count ?? 0,
        comments: video.comment_count ?? 0,
        shares: video.share_count ?? 0,
      },
      metrics_at: now,
    }).eq("id", target);

    matched += 1;
  }

  // The history. A failed insert is logged, not thrown: the person opening
  // Analytics still gets today's numbers even if the chart misses a point.
  if (connection.brand_id) {
    if (user) {
      const { error } = await admin.from("account_metric_snapshots").insert({
        user_id: connection.user_id,
        brand_id: connection.brand_id,
        connection_id: connection.id,
        platform: connection.platform,
        taken_at: now,
        followers: user.follower_count ?? null,
        likes: user.likes_count ?? null,
        video_count: user.video_count ?? null,
      });
      if (error) console.error("fetch-metrics: account snapshot", connection.id, error.message);
    }

    if (videos.length > 0) {
      const { error } = await admin.from("post_metric_snapshots").insert(
        videos.map((v) => ({
          user_id: connection.user_id,
          brand_id: connection.brand_id,
          connection_id: connection.id,
          platform: connection.platform,
          video_id: v.id,
          post_target_id: targetFor.get(v.id) ?? null,
          title: v.title ?? "",
          description: v.video_description ?? null,
          duration_s: typeof v.duration === "number" ? Math.round(v.duration) : null,
          cover_url: v.cover_image_url ?? null,
          share_url: v.share_url ?? null,
          posted_at: v.create_time ? new Date(v.create_time * 1000).toISOString() : null,
          taken_at: now,
          views: v.view_count ?? 0,
          likes: v.like_count ?? 0,
          comments: v.comment_count ?? 0,
          shares: v.share_count ?? 0,
        })),
      );
      if (error) console.error("fetch-metrics: video snapshots", connection.id, error.message);
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

  return {
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
    errors: [profile.error?.message, listed.error].filter(
      (message) => message && message !== "ok",
    ),
  };
}

/** Relearning must never cost somebody their numbers. */
async function relearn(admin: SupabaseClient, brandId: string | null, userId: string) {
  if (!brandId) return;
  try {
    await learn(admin, brandId, userId);
  } catch (error) {
    console.error("fetch-metrics: learn", brandId, error);
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    // --- the six-hour loop: every active account ------------------------------

    const cronHeader = request.headers.get("x-cron-secret");
    if (cronHeader !== null) {
      if (!CRON_SECRET || !sameSecret(cronHeader, CRON_SECRET)) {
        return json({ error: "no" }, 401);
      }

      const admin = createClient(SUPABASE_URL, SERVICE_KEY);
      const { data: connections } = await admin
        .from("platform_connections")
        .select("id, user_id, brand_id, username, platform")
        .eq("status", "active")
        .eq("platform", "tiktok");

      let measured = 0;
      let failed = 0;
      const brands = new Map<string, string>();
      // One at a time: TikTok rate-limits per app, and one account's expired
      // token must not stop everybody else's reading.
      for (const connection of (connections ?? []) as Connection[]) {
        try {
          await measure(admin, connection);
          measured += 1;
          if (connection.brand_id) brands.set(connection.brand_id, connection.user_id);
        } catch (error) {
          failed += 1;
          console.error("fetch-metrics: cron", connection.id, error);
        }
      }
      for (const [brandId, userId] of brands) await relearn(admin, brandId, userId);

      return json({ measured, failed, learned: brands.size });
    }

    // --- the phone: the brand on screen ----------------------------------------

    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);

    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const body = await request.json().catch(() => ({})) as { brand_id?: string };

    let query = asUser
      .from("platform_connections")
      .select("id, user_id, brand_id, username, platform")
      .eq("status", "active");
    if (body.brand_id) query = query.eq("brand_id", body.brand_id);

    const { data: connection } = await query.limit(1).maybeSingle();
    if (!connection) throw new PublicError("No account is connected.", 404);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const result = await measure(admin, connection as Connection);
    await relearn(admin, (connection as Connection).brand_id, auth.user.id);
    return json(result);
  } catch (error) {
    return fail(error);
  }
});
