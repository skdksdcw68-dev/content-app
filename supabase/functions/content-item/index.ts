/**
 * One of the person's own videos, taken from "file on the phone" to "a post in
 * the plan, checked and waiting for approval" -- in three real steps the app
 * shows as they happen.
 *
 *   understand  Look at the video (frames the phone sends) with what the brand
 *               has written down, write the hook, caption, CTA and hashtags,
 *               and put the post into the running plan at the next open slot.
 *   prepare     Attach the uploaded file: rights cleared, TikTok variant,
 *               target with the caption exactly as it will be posted.
 *   validate    Check it against the account as it is right now: connection,
 *               TikTok's own limits (creator_info), size, length, format,
 *               caption length, time, daily cap.
 *
 * Nothing is scheduled to publish here. That happens on approval.
 *
 * Operator mode: called with the service-role key and a `user_id`, it acts for
 * that user. The service-role key can already do anything; this only lets the
 * same code path be exercised without a phone.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { MODELS } from "../_shared/route.ts";
import { attachUpload } from "../_shared/attach.ts";
import { creatorInfo } from "../_shared/tiktok.ts";
import { preferenceBlock } from "../_shared/brand-profile.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");
const MODEL = Deno.env.get("VISION_MODEL") ?? MODELS.chat;

const MAX_BYTES = 60 * 1024 * 1024;
const MAX_CAPTION = 2200;

interface Body {
  step?: "understand" | "prepare" | "validate" | "compose" | "write";
  /** compose/write: the person's own words and tags. */
  caption?: string;
  hashtags?: string[];
  /** compose: the frame chosen as the cover, in milliseconds. */
  cover_ms?: number;
  /** compose/validate: DIRECT_POST or UPLOAD_TO_DRAFT. */
  mode?: string;
  brand_id?: string;
  post_id?: string;
  storage_path?: string;
  /** Up to four JPEG frames, base64, taken on the phone. */
  frames?: string[];
  duration_s?: number;
  width?: number;
  height?: number;
  file_name?: string;
  /** Anything the person typed about the video. */
  note?: string;
  /** Operator mode only. */
  user_id?: string;
}

interface Check {
  key: string;
  title: string;
  ok: boolean;
  detail: string;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const body = (await request.json().catch(() => ({}))) as Body;
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const userId = await caller(request, body);

    if (!body.brand_id) throw new PublicError("brand_id is required.");
    const { data: brand } = await admin
      .from("brands")
      .select("id, name, niche, audience, timezone, profile")
      .eq("id", body.brand_id)
      .eq("user_id", userId)
      .maybeSingle();
    if (!brand) throw new PublicError("That brand is not yours.", 404);

    switch (body.step) {
      case "understand": return json(await understand(admin, userId, brand, body));
      case "prepare":    return json(await prepare(admin, userId, brand, body));
      case "validate":   return json(await validate(admin, userId, brand, body));
      case "compose":    return json(await compose(admin, userId, brand, body));
      case "write":      return json(await write(brand, body, admin));
      default:           throw new PublicError("Unknown step.");
    }
  } catch (error) {
    return fail(error);
  }
});

async function caller(request: Request, body: Body): Promise<string> {
  const authorization = request.headers.get("Authorization") ?? "";
  // verify_jwt is on, so the gateway has already checked the signature; the
  // role claim can be read as given.
  if (authorization === `Bearer ${SERVICE_KEY}` || jwtRole(authorization) === "service_role") {
    if (!body.user_id) throw new PublicError("user_id is required in operator mode.");
    return body.user_id;
  }
  if (!authorization) throw new PublicError("Sign in first.", 401);
  const asUser = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authorization } } });
  const { data: auth } = await asUser.auth.getUser();
  if (!auth.user) throw new PublicError("Sign in first.", 401);
  return auth.user.id;
}

function jwtRole(authorization: string): string | null {
  const token = authorization.replace(/^Bearer\s+/i, "");
  const part = token.split(".")[1];
  if (!part) return null;
  try {
    const payload = JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=")));
    return typeof payload.role === "string" ? payload.role : null;
  } catch {
    return null;
  }
}

type Brand = { id: string; name: string; niche: string; audience: string; timezone: string; profile?: unknown };
type Admin = ReturnType<typeof createClient>;

// ---------------------------------------------------------------- understand

async function understand(admin: Admin, userId: string, brand: Brand, body: Body) {
  if (!OPENAI_KEY) throw new PublicError("The writer is not configured yet.", 503);

  const { data: memory } = await admin
    .from("brand_memory")
    .select("fact")
    .eq("brand_id", brand.id)
    .order("created_at", { ascending: false })
    .limit(20);

  const facts = [
    brand.niche ? `What ${brand.name} is: ${brand.niche}` : "",
    brand.audience ? `Audience: ${brand.audience}` : "",
    ...((memory ?? []) as { fact: string }[]).map((m) => m.fact),
  ].map((f) => f.trim()).filter(Boolean).filter((f, i, all) => all.indexOf(f) === i);

  if (facts.length === 0) {
    throw new PublicError(`Tell Autocast what ${brand.name} is first (You → your brand), so it doesn't guess.`, 409);
  }

  const frames = (body.frames ?? []).filter((f) => typeof f === "string" && f.length > 100).slice(0, 4);
  if (frames.length === 0) throw new PublicError("No frames came with the video.");

  const system = [
    `You write one short-form video post for ${brand.name}, for a video the owner recorded.`,
    'Return JSON only: {"concept":string,"hook":string,"caption":string,"cta":string,"hashtags":[string],"format":"screen_recording"|"talking"|"product_shot"|"other"}.',
    "concept: what the video visibly shows, in one or two plain sentences. Describe only what is on screen.",
    "hook: the first line a viewer reads. Under 70 characters. No hype words, no emoji.",
    "caption: 1-2 sentences under 150 characters that match what the video shows.",
    "cta: one short call to action, e.g. inviting people to try the app. No promises, no prices.",
    "hashtags: 3 to 5, lowercase, each starting with #, about the topic and the brand name. No invented trends.",
    "FACTS below are everything true about the brand. NEVER claim a feature, number, accuracy, price, rating, award, user count or result that is not in FACTS or plainly visible on screen. If the screen shows a number (like calories), you may mention it as what the video shows, not as a promise.",
    "Never invent a person, a testimonial or a before/after story.",
    "Never claim speed or ease (instantly, in seconds, effortless, easy, fast) unless FACTS say so. Never say accurate, best, #1 or guaranteed.",
  ].join("\n");

  const content: unknown[] = [
    {
      type: "text",
      text: [
        "FACTS:",
        ...facts.map((f) => `- ${f}`),
        preferenceBlock(brand.profile),
        body.note ? `\nThe owner says about this video: ${body.note}` : "",
        `\nVideo: ${body.duration_s ? `${Math.round(body.duration_s)} seconds` : "length unknown"}, frames in order:`,
      ].join("\n"),
    },
    ...frames.map((frame) => ({ type: "image_url", image_url: { url: `data:image/jpeg;base64,${frame}`, detail: "low" } })),
  ];

  // The prompt alone did not hold: "instantly" and "quick scan" came back
  // twice with the rule in place. Checked here, rewritten once, then removed.
  type Draft = { concept?: string; hook?: string; caption?: string; cta?: string; hashtags?: string[]; format?: string };
  let draft: Draft = {};
  let tokens = 0;
  const messages: unknown[] = [{ role: "system", content: system }, { role: "user", content }];
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${OPENAI_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model: MODEL, temperature: 0.4, response_format: { type: "json_object" }, messages }),
    });
    const completion = await response.json();
    if (!response.ok) {
      console.error("openai", completion?.error);
      throw new PublicError("Autocast couldn't look at the video just now. Try again.", 502);
    }
    tokens += completion.usage?.total_tokens ?? 0;
    const text = completion.choices?.[0]?.message?.content ?? "{}";
    try { draft = JSON.parse(text); } catch { draft = {}; }
    const found = unsupportedClaims([draft.hook, draft.caption, draft.cta].join(" "));
    if (found.length === 0) break;
    messages.push({ role: "assistant", content: text });
    messages.push({ role: "user", content: `Remove these unsupported claims and rewrite: ${found.join(", ")}. Same JSON shape.` });
  }
  draft.hook = stripClaims(draft.hook ?? "");
  draft.caption = stripClaims(draft.caption ?? "");
  draft.cta = stripClaims(draft.cta ?? "");

  const hook = (draft.hook ?? "").trim().slice(0, 200);
  if (!hook) throw new PublicError("Autocast couldn't write a post for this video. Try again.", 502);
  const hashtags = (draft.hashtags ?? [])
    .filter((h) => typeof h === "string" && h.trim())
    .map((h) => (h.trim().startsWith("#") ? h.trim() : `#${h.trim()}`).toLowerCase().replace(/\s+/g, ""))
    .slice(0, 5);

  // ------------------------------------------------ into the running plan
  const { data: settings } = await admin
    .from("brand_settings").select("posts_per_day").eq("brand_id", brand.id).maybeSingle();
  const perDay = Math.max(1, Math.min(6, settings?.posts_per_day ?? 1));
  const today = localDate(new Date().toISOString(), brand.timezone);

  let { data: plan } = await admin
    .from("content_plans")
    .select("id, title, starts_on, days")
    .eq("brand_id", brand.id)
    .eq("status", "active")
    .maybeSingle();

  if (!plan) {
    const { data: created, error } = await admin
      .from("content_plans")
      .insert({
        user_id: userId,
        brand_id: brand.id,
        title: `${brand.name} — your videos`,
        objective: `Publish ${brand.name}'s own videos on a steady schedule.`,
        platforms: ["tiktok"],
        status: "active",
        starts_on: today,
        days: 30,
        posts_per_day: perDay,
        brief: "Created for your uploaded videos.",
        approved_at: new Date().toISOString(),
        approved_by: userId,
      })
      .select("id, title, starts_on, days")
      .single();
    if (error) throw error;
    plan = created;
    await admin.rpc("log_activity", {
      p_user: userId, p_brand: brand.id, p_post: null, p_kind: "plan", p_actor: "autocast",
      p_title: `Started “${created.title}”`, p_detail: "A running plan for your own videos.",
    });
  }

  const { data: slots, error: slotError } = await admin.rpc("allocate_slots", {
    p_brand_id: brand.id,
    p_starts_on: today,
    p_days: 14,
    p_posts_per_day: perDay,
  });
  if (slotError) throw slotError;
  const slot = ((slots ?? []) as { slot_at: string; pillar_id: string | null; slot_index: number }[])[0];
  if (!slot) throw new PublicError("There's no open slot in the next two weeks.", 409);

  const dayIndex = Math.max(0, daysBetween(plan.starts_on, localDate(slot.slot_at, brand.timezone)));
  if (dayIndex >= plan.days) {
    await admin.from("content_plans").update({ days: Math.min(60, dayIndex + 1) }).eq("id", plan.id);
  }

  const { data: post, error: postError } = await admin
    .from("posts")
    .insert({
      user_id: userId,
      brand_id: brand.id,
      plan_id: plan.id,
      pillar_id: slot.pillar_id,
      day_index: dayIndex,
      slot_index: slot.slot_index,
      format: "video",
      hook,
      script: (draft.caption ?? "").trim().slice(0, 1500),
      cta: (draft.cta ?? "").trim().slice(0, 200),
      hashtags,
      concept: (draft.concept ?? "").trim().slice(0, 600),
      rationale: `Your own video${body.file_name ? ` (${body.file_name.slice(0, 60)})` : ""}, placed in the next open slot.`,
      status: "scripted",
      render_tier: "eager",
      media_strategy: "user_upload",
      scheduled_for: slot.slot_at,
    })
    .select("id, plan_id, hook, script, cta, hashtags, concept, scheduled_for")
    .single();
  if (postError) throw postError;

  await admin.rpc("log_activity", {
    p_user: userId, p_brand: brand.id, p_post: post.id, p_kind: "understood", p_actor: "autocast",
    p_title: "Understood the video", p_detail: post.concept,
  });

  return {
    post_id: post.id,
    plan_id: post.plan_id,
    plan_title: plan.title,
    hook: post.hook,
    caption: post.script,
    cta: post.cta,
    hashtags: post.hashtags,
    concept: post.concept,
    scheduled_for: post.scheduled_for,
    tokens,
  };
}

// ------------------------------------------------------------------- prepare

async function prepare(admin: Admin, userId: string, brand: Brand, body: Body) {
  if (!body.post_id || !body.storage_path) throw new PublicError("post_id and storage_path are required.");
  const post = await ownPost(admin, userId, brand.id, body.post_id);

  const connection = await activeConnection(admin, brand.id);
  if (!connection) {
    await admin.rpc("log_activity", {
      p_user: userId, p_brand: brand.id, p_post: post.id, p_kind: "held", p_actor: "autocast",
      p_title: "Waiting for a TikTok connection", p_detail: `Connect TikTok to ${brand.name} to publish this.`,
    });
    return { ok: false, reason: "no_connection" };
  }

  const caption = [post.script ?? "", post.cta ?? ""].map((s: string) => s.trim()).filter(Boolean).join(" ");
  const attached = await attachUpload(admin, {
    userId,
    brandId: brand.id,
    connection,
    storagePath: body.storage_path,
    postId: post.id,
    caption,
    hashtags: post.hashtags ?? [],
    durationMs: body.duration_s ? Math.round(body.duration_s * 1000) : null,
    width: body.width ?? null,
    height: body.height ?? null,
  });

  await admin.rpc("log_activity", {
    p_user: userId, p_brand: brand.id, p_post: post.id, p_kind: "prepared", p_actor: "autocast",
    p_title: "Prepared for TikTok",
    p_detail: `Video (${(attached.byteSize / 1_048_576).toFixed(1)} MB), caption and ${(post.hashtags ?? []).length} hashtags attached for @${connection.username}.`,
  });

  return { ok: true, post_target_id: attached.postTargetId, asset_id: attached.assetId, username: connection.username };
}

// ------------------------------------------------------------------ validate

async function validate(admin: Admin, userId: string, brand: Brand, body: Body) {
  if (!body.post_id) throw new PublicError("post_id is required.");
  const post = await ownPost(admin, userId, brand.id, body.post_id);

  const { data: target } = await admin
    .from("post_targets")
    .select("id, connection_id, caption, hashtags, platform_connections(username, status), post_assets(media_assets(byte_size, mime, duration_ms, width, height))")
    .eq("post_id", post.id)
    .limit(1)
    .maybeSingle();

  const checks: Check[] = [];
  const add = (key: string, title: string, ok: boolean, detail: string) => checks.push({ key, title, ok, detail });

  if (!target) {
    add("prepared", "Prepared", false, "The video isn't attached yet.");
    return finish(admin, userId, brand, post.id, checks, null);
  }

  const conn = target.platform_connections as unknown as { username: string; status: string } | null;
  add("account", "TikTok account", conn?.status === "active",
    conn?.status === "active" ? `Connected as @${conn.username}` : "Reconnect TikTok in You → Accounts.");

  let info: Awaited<ReturnType<typeof creatorInfo>> | null = null;
  try {
    info = await creatorInfo(admin, target.connection_id);
    await admin.from("creator_snapshots").insert({
      connection_id: target.connection_id,
      username: info.creator_username ?? "",
      nickname: info.creator_nickname ?? "",
      avatar_url: info.creator_avatar_url ?? "",
      privacy_level_options: info.privacy_level_options,
      comment_disabled: info.comment_disabled ?? false,
      duet_disabled: info.duet_disabled ?? false,
      stitch_disabled: info.stitch_disabled ?? false,
      max_video_post_duration_sec: info.max_video_post_duration_sec ?? 600,
    });
    // Until TikTok has reviewed Autocast it refuses posts from PUBLIC accounts
    // (unaudited_client_can_only_post_to_private_accounts). A public account
    // is one that is offered PUBLIC_TO_EVERYONE.
    // The inbox route (drafts) is left to TikTok to decide.
    if (Deno.env.get("TIKTOK_APP_AUDITED") !== "true" && body.mode !== "UPLOAD_TO_DRAFT") {
      const isPublic = info.privacy_level_options.includes("PUBLIC_TO_EVERYONE");
      add("private", "Account set to private", !isPublic,
        isPublic
          ? `TikTok only accepts posts from private accounts while it reviews Autocast. Set @${info.creator_username ?? "your account"} to Private in TikTok → Settings → Privacy, then check again.`
          : "Private — TikTok will accept the post.");
    }
    const onlyPrivate = info.privacy_level_options.length === 1 && info.privacy_level_options[0] === "SELF_ONLY";
    add("posting", "TikTok allows posting", info.privacy_level_options.length > 0,
      onlyPrivate
        ? "Yes — as private (only you) while TikTok reviews Autocast."
        : `Yes — ${info.privacy_level_options.map(privacyName).join(", ")}.`);
  } catch (error) {
    add("posting", "TikTok allows posting", false, error instanceof Error ? error.message : "TikTok didn't answer.");
  }

  const media = ((target.post_assets ?? []) as unknown as { media_assets: { byte_size: number; mime: string; duration_ms: number | null; width: number | null; height: number | null } }[])[0]?.media_assets;
  if (!media) {
    add("video", "Video attached", false, "No video on this post.");
  } else {
    add("size", "File size", media.byte_size <= MAX_BYTES,
      `${(media.byte_size / 1_048_576).toFixed(1)} MB${media.byte_size <= MAX_BYTES ? "" : " — over the 60 MB Autocast can send today"}`);
    add("format", "Format", /mp4|quicktime/.test(media.mime), media.mime.includes("quicktime") ? "MOV" : "MP4");
    if (media.duration_ms) {
      const seconds = media.duration_ms / 1000;
      const max = info?.max_video_post_duration_sec ?? 600;
      // Only TikTok's stated limit, the account's maximum. A minimum was
      // guessed here once and blocked a real 2-second clip.
      add("length", "Length", seconds <= max,
        `${seconds < 10 ? seconds.toFixed(1) : Math.round(seconds)}s${seconds > max ? ` — this account allows up to ${max}s` : ""}`);
    }
    if (media.width && media.height) {
      const short = Math.min(media.width, media.height);
      add("resolution", "Resolution", short >= 360,
        `${media.width}×${media.height}${media.height > media.width ? " (vertical)" : ""}`);
    }
  }

  const fullCaption = [target.caption ?? "", ...((target.hashtags ?? []) as string[])].filter(Boolean).join(" ");
  add("caption", "Caption", fullCaption.length <= MAX_CAPTION,
    fullCaption.length === 0 ? "No caption" : `${fullCaption.length} of ${MAX_CAPTION} characters`);

  // A post with no time goes out when the person taps Post.
  const when = post.scheduled_for ? new Date(post.scheduled_for) : null;
  if (when) {
    add("time", "Scheduled time", when.getTime() > Date.now(),
      when.getTime() > Date.now() ? "In the future" : "The time has passed — pick a new one when you approve.");
  }

  const { data: rate } = await admin
    .from("account_rate_state").select("day_count, day_window, max_per_day").eq("connection_id", target.connection_id).maybeSingle();
  const usedToday = rate && rate.day_window === new Date().toISOString().slice(0, 10) ? rate.day_count : 0;
  add("cap", "Daily posting cap", !rate || usedToday < rate.max_per_day,
    rate ? `${usedToday} of ${rate.max_per_day} used today` : "No limit recorded");

  return finish(admin, userId, brand, post.id, checks, info);
}

async function finish(
  admin: Admin, userId: string, brand: Brand, postId: string, checks: Check[],
  info: { privacy_level_options: string[]; creator_username?: string; creator_avatar_url?: string; max_video_post_duration_sec?: number } | null,
) {
  // The time check is advice, not a blocker: approval picks a new time.
  const blocking = checks.filter((c) => !c.ok && c.key !== "time");
  await admin.rpc("log_activity", {
    p_user: userId, p_brand: brand.id, p_post: postId,
    p_kind: blocking.length === 0 ? "validated" : "validation_failed", p_actor: "autocast",
    p_title: blocking.length === 0 ? "Checked — ready for your review" : "Needs a fix before it can post",
    p_detail: blocking.length === 0
      ? `${checks.length} checks passed against your TikTok account.`
      : blocking.map((c) => `${c.title}: ${c.detail}`).join(" · "),
  });
  return {
    ok: blocking.length === 0,
    checks,
    privacy_options: info?.privacy_level_options ?? [],
    username: info?.creator_username ?? null,
    avatar_url: info?.creator_avatar_url ?? null,
  };
}

// ------------------------------------------------------------------- compose

/**
 * A post the person wrote themselves: their video, their caption, their tags.
 * No plan, no brand facts needed -- a connected account is enough (Abel, 18
 * Sep). Attached and checked in one call; approving and posting follow.
 */
async function compose(admin: Admin, userId: string, brand: Brand, body: Body) {
  if (!body.storage_path) throw new PublicError("storage_path is required.");
  const connection = await activeConnection(admin, brand.id);
  if (!connection) throw new PublicError("Connect TikTok first (You → Accounts).", 409);

  const caption = (body.caption ?? "").trim().slice(0, 2000);
  const hashtags = cleanTags(body.hashtags ?? []);
  const firstLine = caption.split("\n")[0].replace(/(^|\s)#\w+/g, "").trim();

  const { data: post, error: postError } = await admin
    .from("posts")
    .insert({
      user_id: userId,
      brand_id: brand.id,
      format: "video",
      hook: (firstLine || body.file_name || "Your video").slice(0, 120),
      script: caption,
      hashtags,
      concept: "",
      rationale: "You posted this yourself.",
      status: "scripted",
      render_tier: "eager",
      media_strategy: "user_upload",
    })
    .select("id")
    .single();
  if (postError) throw postError;

  const attached = await attachUpload(admin, {
    userId,
    brandId: brand.id,
    connection,
    storagePath: body.storage_path,
    postId: post.id,
    caption,
    hashtags,
    durationMs: body.duration_s ? Math.round(body.duration_s * 1000) : null,
    width: body.width ?? null,
    height: body.height ?? null,
  });

  if (typeof body.cover_ms === "number" && body.cover_ms > 0) {
    await admin.from("post_targets").update({ video_cover_ms: Math.round(body.cover_ms) }).eq("id", attached.postTargetId);
  }

  await admin.rpc("log_activity", {
    p_user: userId, p_brand: brand.id, p_post: post.id, p_kind: "prepared", p_actor: "you",
    p_title: "You wrote the post",
    p_detail: `Original file (${(attached.byteSize / 1_048_576).toFixed(1)} MB), sent as is — no re-compression.`,
  });

  const report = await validate(admin, userId, brand, { ...body, post_id: post.id });
  return { post_id: post.id, post_target_id: attached.postTargetId, ...report };
}

// --------------------------------------------------------------------- write

/**
 * "Write with AI": the person's own caption, made better -- same meaning,
 * same language, same voice -- plus hashtags. With nothing typed it writes
 * from the frames. Uses the brand's facts when there are any; never needs
 * them.
 */
async function write(brand: Brand, body: Body, admin: Admin) {
  if (!OPENAI_KEY) throw new PublicError("The writer is not configured yet.", 503);
  const draft = (body.caption ?? "").trim();
  const frames = (body.frames ?? []).filter((f) => typeof f === "string" && f.length > 100).slice(0, 3);
  if (!draft && frames.length === 0) throw new PublicError("Write something or pick a video first.");

  const { data: memory } = await admin
    .from("brand_memory").select("fact").eq("brand_id", brand.id).order("created_at", { ascending: false }).limit(10);
  const facts = [
    brand.niche ? `About ${brand.name}: ${brand.niche}` : "",
    ...((memory ?? []) as { fact: string }[]).map((m) => m.fact),
  ].map((f) => f.trim()).filter(Boolean).filter((f, i, all) => all.indexOf(f) === i);

  const system = [
    "You improve a TikTok caption for the person who wrote it.",
    'Return JSON only: {"caption":string,"hashtags":[string]}.',
    draft
      ? "caption: their caption, made clearer and more engaging. Keep their meaning, their language and their voice. Keep any @mentions exactly. Under 150 characters unless theirs is longer. No hashtags inside the caption."
      : "caption: a short caption for this video, written from what is visibly on screen. Under 150 characters. No hashtags inside the caption.",
    "hashtags: 4 to 6, lowercase, each starting with #, relevant to the video and caption. Mix broad and specific. No invented trends.",
    "NEVER add a fact, number, feature, price, result or claim that is not in their caption, the FACTS, or visible on screen. Never claim speed, ease, accuracy or being the best. Never invent a person or testimonial.",
  ].join("\n");

  const content: unknown[] = [{
    type: "text",
    text: [
      facts.length ? `FACTS:\n${facts.map((f) => `- ${f}`).join("\n")}` : "No facts about the account were given.",
      preferenceBlock(brand.profile),
      draft ? `\nTheir caption:\n${draft}` : "\nThey wrote nothing yet.",
      ...(body.hashtags?.length ? [`\nTheir hashtags: ${body.hashtags.join(" ")}`] : []),
      frames.length ? "\nFrames from the video:" : "",
    ].join("\n"),
  }, ...frames.map((frame) => ({ type: "image_url", image_url: { url: `data:image/jpeg;base64,${frame}`, detail: "low" } }))];

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: MODEL,
      temperature: 0.6,
      response_format: { type: "json_object" },
      messages: [{ role: "system", content: system }, { role: "user", content }],
    }),
  });
  const completion = await response.json();
  if (!response.ok) {
    console.error("openai", completion?.error);
    throw new PublicError("The writer couldn't be reached just now. Try again.", 502);
  }
  let out: { caption?: string; hashtags?: string[] } = {};
  try { out = JSON.parse(completion.choices?.[0]?.message?.content ?? "{}"); } catch { /* checked below */ }

  // Only claims the person did not write themselves are removed.
  const theirs = unsupportedClaims(draft);
  const added = unsupportedClaims(out.caption ?? "").filter((w) => !theirs.includes(w));
  let caption = (out.caption ?? "").trim();
  if (added.length) {
    caption = caption.replace(CLAIMS, (word) => (theirs.includes(word.toLowerCase()) ? word : ""))
      .replace(/\s+([.,!?])/g, "$1").replace(/\s{2,}/g, " ").trim();
  }
  if (!caption) caption = draft;

  return { caption, hashtags: cleanTags(out.hashtags ?? []) };
}

function cleanTags(tags: string[]): string[] {
  return tags
    .filter((t) => typeof t === "string" && t.trim())
    .map((t) => (t.trim().startsWith("#") ? t.trim() : `#${t.trim()}`).toLowerCase().replace(/\s+/g, ""))
    .filter((t, i, all) => t.length > 1 && all.indexOf(t) === i)
    .slice(0, 8);
}

// --------------------------------------------------------------------- utils

async function ownPost(admin: Admin, userId: string, brandId: string, postId: string) {
  const { data: post } = await admin
    .from("posts")
    .select("id, brand_id, status, script, cta, hashtags, scheduled_for")
    .eq("id", postId)
    .eq("user_id", userId)
    .maybeSingle();
  if (!post || post.brand_id !== brandId) throw new PublicError("That post is not yours.", 404);
  if (post.status === "posted") throw new PublicError("That post has already gone out.", 409);
  return post;
}

async function activeConnection(admin: Admin, brandId: string) {
  const { data } = await admin
    .from("platform_connections")
    .select("id, platform, username, status")
    .eq("brand_id", brandId)
    .eq("platform", "tiktok")
    .eq("status", "active")
    .order("connected_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  return data as { id: string; platform: string; username: string; status: string } | null;
}

const CLAIMS = /\b(instant(ly)?|in (a few |mere )?seconds|in no time|effortless(ly)?|easy|easily|fast(er|est)?|quick(ly|er)?|rapid(ly)?|accurate(ly)?|precise(ly)?|best|number one|guarantee[ds]?|proven)\b|#1\b/gi;

function unsupportedClaims(text: string): string[] {
  return [...new Set((text.match(CLAIMS) ?? []).map((w) => w.toLowerCase()))];
}

function stripClaims(text: string): string {
  return text
    .replace(CLAIMS, "")
    .replace(/\s+([.,!?])/g, "$1")
    .replace(/\s{2,}/g, " ")
    .replace(/\ba\s+(?=[aeiou])/gi, "an ")
    .trim();
}

function privacyName(level: string): string {
  switch (level) {
    case "PUBLIC_TO_EVERYONE": return "everyone";
    case "MUTUAL_FOLLOW_FRIENDS": return "friends";
    case "FOLLOWER_OF_CREATOR": return "followers";
    case "SELF_ONLY": return "only you";
    default: return level;
  }
}

function localDate(iso: string, timezone: string): string {
  try {
    return new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" })
      .format(new Date(iso));
  } catch {
    return iso.slice(0, 10);
  }
}

function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(b) - Date.parse(a)) / 86_400_000);
}
