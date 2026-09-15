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
 * a screen -- and, since 0037, it also APPENDS every reading to the snapshot
 * tables, because a chart needs yesterday's number as well as today's.
 *
 * Two ways in:
 *   - the phone, with a session, for one connection (the brand on screen);
 *   - the database, every six hours, with `x-cron-secret`, for all of them.
 */

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { accessToken } from "../_shared/tiktok.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");

interface Video {
  id: string;
  title?: string;
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
          video_id: v.id,
          post_target_id: targetFor.get(v.id) ?? null,
          title: v.title ?? "",
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
    errors: [profile.error?.message, listed.error?.message].filter(
      (message) => message && message !== "ok",
    ),
  };
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
        .select("id, user_id, brand_id, username")
        .eq("status", "active")
        .eq("platform", "tiktok");

      let measured = 0;
      let failed = 0;
      // One at a time: TikTok rate-limits per app, and one account's expired
      // token must not stop everybody else's reading.
      for (const connection of (connections ?? []) as Connection[]) {
        try {
          await measure(admin, connection);
          measured += 1;
        } catch (error) {
          failed += 1;
          console.error("fetch-metrics: cron", connection.id, error);
        }
      }

      return json({ measured, failed });
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
      .select("id, user_id, brand_id, username")
      .eq("status", "active");
    if (body.brand_id) query = query.eq("brand_id", body.brand_id);

    const { data: connection } = await query.limit(1).maybeSingle();
    if (!connection) throw new PublicError("No account is connected.", 404);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    return json(await measure(admin, connection as Connection));
  } catch (error) {
    return fail(error);
  }
});
