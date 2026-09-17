/**
 * A plan somebody already has, brought in as a proposal.
 *
 * Abel writes plans in ChatGPT and in documents (DOCX, PDF, a ZIP of them, or
 * pasted text). Retyping thirty posts is the step that kills the habit, so
 * this reads the file, pulls out the posts that are IN it -- never new ones --
 * and lays them onto real slots the same way propose-plan does.
 *
 * The result is a `proposed` plan, the same object propose-plan makes, so the
 * review screen and its one Approve button work unchanged. Nothing is
 * scheduled until activate_plan().
 *
 * Times: when the document names a time for a post, that time is used in the
 * brand's timezone. Otherwise the slot allocate_slots() picked is used.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { strFromU8, unzipSync } from "https://esm.sh/fflate@0.8.2";
import { extractText, getDocumentProxy } from "npm:unpdf@0.12.1";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { MODELS } from "../_shared/route.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");

/** Reading a long document faithfully is worth the mid model; nano skipped
 *  posts and merged days in a long plan. */
const MODEL = Deno.env.get("IMPORT_MODEL") ?? MODELS.chat;

/** Characters per extraction call. A 30-day plan with scripts is ~25K. */
const CHUNK = 18_000;
const MAX_TEXT = 120_000;
const MAX_DAYS = 60;

interface Body {
  brand_id?: string;
  path?: string;
  file_name?: string;
  text?: string;
  starts_on?: string;
}

interface Found {
  day?: number | null;
  date?: string | null;
  time?: string | null;
  hook?: string;
  caption?: string;
  concept?: string;
  hashtags?: string[];
  cta?: string;
  format?: string;
}

interface Slot {
  slot_at: string;
  pillar_id: string | null;
  day_index: number;
  slot_index: number;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    if (!OPENAI_KEY) throw new PublicError("The reader is not configured yet.", 503);

    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);
    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);
    const userId = auth.user.id;

    const body = (await request.json().catch(() => ({}))) as Body;

    const brandQuery = asUser.from("brands").select("id, name, timezone");
    const { data: brand } = await (
      typeof body.brand_id === "string" && body.brand_id.length === 36
        ? brandQuery.eq("id", body.brand_id)
        : brandQuery.order("created_at", { ascending: true })
    ).limit(1).maybeSingle();
    if (!brand) throw new PublicError("Set up your brand first.", 400);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // ---------------------------------------------------------------- text
    let text = (body.text ?? "").trim();
    const fileName = (body.file_name ?? "").trim().slice(0, 120);
    if (!text && body.path) {
      // Only the caller's own uploads, the same rule agent-chat applies.
      if (!body.path.startsWith(`${userId}/uploads/`) || body.path.includes("..")) {
        throw new PublicError("That file isn't yours to read.", 403);
      }
      const { data: blob, error } = await admin.storage.from("artifacts").download(body.path);
      if (error || !blob) throw new PublicError("Couldn't open the file. Try uploading it again.", 400);
      text = await readAny(new Uint8Array(await blob.arrayBuffer()), fileName || body.path);
    }
    text = text.replace(/\r/g, "").replace(/\n{3,}/g, "\n\n").trim().slice(0, MAX_TEXT);
    if (text.length < 30) {
      throw new PublicError("Couldn't find any plan text in that. Try a DOCX, PDF, text file, or paste it.", 422);
    }

    // ------------------------------------------------------------- extract
    let title = "";
    let objective = "";
    const found: Found[] = [];
    let tokens = 0;
    for (let start = 0; start < text.length; start += CHUNK) {
      const piece = text.slice(start, start + CHUNK);
      const result = await extract(piece, found.length, todayIn(brand.timezone));
      tokens += result.tokens;
      if (!title && result.title) title = result.title;
      if (!objective && result.objective) objective = result.objective;
      found.push(...result.posts);
    }

    const posts = found
      .map((p) => ({ ...p, hook: (p.hook ?? "").trim(), caption: (p.caption ?? "").trim(), concept: (p.concept ?? "").trim() }))
      .filter((p) => p.hook || p.caption || p.concept);

    if (posts.length === 0) {
      throw new PublicError("That doesn't look like a content plan — no posts were found in it.", 422);
    }

    // ------------------------------------------------------------ arrange
    // Day numbers when the document has them; otherwise dates; otherwise one
    // post per day in document order.
    const withDates = posts.filter((p) => validDate(p.date)).length;
    const withDays = posts.filter((p) => typeof p.day === "number" && p.day! > 0).length;
    let keyed: Array<Found & { dayIndex: number }>;
    if (withDays >= posts.length * 0.6) {
      let last = 0;
      keyed = posts.map((p) => {
        const d = typeof p.day === "number" && p.day > 0 ? Math.round(p.day) : last || 1;
        last = d;
        return { ...p, dayIndex: d - 1 };
      });
      const min = Math.min(...keyed.map((p) => p.dayIndex));
      keyed = keyed.map((p) => ({ ...p, dayIndex: p.dayIndex - min }));
    } else if (withDates >= posts.length * 0.6) {
      const first = posts.map((p) => p.date).filter(validDate).sort()[0]!;
      let last = 0;
      keyed = posts.map((p) => {
        const d = validDate(p.date) ? daysBetween(first, p.date!) : last;
        last = d;
        return { ...p, dayIndex: Math.max(0, d) };
      });
    } else {
      keyed = posts.map((p, i) => ({ ...p, dayIndex: i }));
    }

    keyed = keyed.filter((p) => p.dayIndex < MAX_DAYS);
    const days = Math.max(...keyed.map((p) => p.dayIndex)) + 1;
    const perDayCount = new Map<number, number>();
    for (const p of keyed) perDayCount.set(p.dayIndex, (perDayCount.get(p.dayIndex) ?? 0) + 1);
    const perDay = Math.min(6, Math.max(...perDayCount.values()));

    // Day 1 is tomorrow: starting today lost Day 1 whenever today's slot had
    // passed. A plan written with dates starts on its first date if that is
    // still ahead.
    const today = todayIn(brand.timezone);
    const tomorrow = addDays(today, 1);
    let startsOn = body.starts_on ?? tomorrow;
    if (!body.starts_on && withDates >= posts.length * 0.6 && withDays < posts.length * 0.6) {
      const first = posts.map((p) => p.date).filter(validDate).sort()[0]!;
      if (first >= today) startsOn = first;
    }

    const { data: slots, error: slotError } = await admin.rpc("allocate_slots", {
      p_brand_id: brand.id,
      p_starts_on: startsOn,
      p_days: days,
      p_posts_per_day: perDay,
    });
    if (slotError) {
      if (slotError.code === "23514" || /quiet hours/.test(slotError.message ?? "")) {
        throw new PublicError("Your quiet hours cover the whole day, so there is nowhere to post. Widen them in settings.", 409);
      }
      throw slotError;
    }
    const byDay = new Map<number, Slot[]>();
    for (const slot of (slots ?? []) as Slot[]) {
      const list = byDay.get(slot.day_index) ?? [];
      list.push(slot);
      byDay.set(slot.day_index, list);
    }
    for (const list of byDay.values()) list.sort((a, b) => a.slot_index - b.slot_index);

    const { data: plan, error: planError } = await admin
      .from("content_plans")
      .insert({
        user_id: userId,
        brand_id: brand.id,
        title: (title || (fileName ? fileName.replace(/\.[a-z0-9]+$/i, "") : "Imported plan")).slice(0, 80),
        status: "proposed",
        starts_on: startsOn,
        days,
        posts_per_day: perDay,
        brief: `Imported from ${fileName || "pasted text"}`,
        objective: objective.slice(0, 300),
        platforms: ["tiktok"],
      })
      .select("id, title, starts_on, days, posts_per_day")
      .single();
    if (planError) throw planError;

    const used = new Map<number, number>();
    const taken = new Set<string>();
    const rows = [];
    let skipped = 0;
    for (const p of keyed) {
      const n = used.get(p.dayIndex) ?? 0;
      const slot = byDay.get(p.dayIndex)?.[n];
      if (!slot) { skipped += 1; continue; }
      used.set(p.dayIndex, n + 1);

      let at = slot.slot_at;
      const named = parseTime(p.time);
      if (named) {
        const local = localDate(slot.slot_at, brand.timezone);
        const iso = zonedToUtc(local, named.h, named.m, brand.timezone);
        if (iso && new Date(iso).getTime() > Date.now() + 10 * 60_000 && !taken.has(iso)) at = iso;
      }
      taken.add(at);

      const hashtags = (p.hashtags ?? []).filter((h) => typeof h === "string" && h.trim()).map((h) => h.trim().startsWith("#") ? h.trim() : `#${h.trim()}`);
      const caption = (p.caption ?? "").replace(/(^|\s)#\w+/g, "").trim();
      rows.push({
        user_id: userId,
        brand_id: brand.id,
        plan_id: plan.id,
        pillar_id: slot.pillar_id,
        day_index: slot.day_index,
        slot_index: slot.slot_index,
        format: p.format === "photo" || p.format === "carousel" ? p.format : "video",
        hook: (p.hook || p.caption || p.concept || "").slice(0, 200),
        script: caption,
        cta: (p.cta ?? "").trim().slice(0, 200),
        hashtags: hashtags.map((h) => h.toLowerCase().replace(/\s+/g, "")).slice(0, 8),
        concept: p.concept ?? "",
        rationale: `From your plan${fileName ? ` "${fileName}"` : ""}, day ${p.dayIndex + 1}.`.slice(0, 300),
        status: "planned",
        render_tier: slot.day_index < 3 ? "eager" : "deferred",
        media_strategy: "generate",
        scheduled_for: at,
      });
    }

    if (rows.length === 0) {
      await admin.from("content_plans").delete().eq("id", plan.id);
      throw new PublicError("Every day in that plan is already taken or in the past.", 409);
    }

    let { error: postsError } = await admin.from("posts").insert(rows);
    if (postsError) {
      // A named time that collides with an existing post: fall back to the
      // slots allocate_slots already proved free.
      const slotsOnly = rows.map((row) => {
        const slot = byDay.get(row.day_index)?.find((s) => s.slot_index === row.slot_index);
        return { ...row, scheduled_for: slot?.slot_at ?? row.scheduled_for };
      });
      ({ error: postsError } = await admin.from("posts").insert(slotsOnly));
      if (postsError) {
        await admin.from("content_plans").delete().eq("id", plan.id);
        throw postsError;
      }
    }

    await admin.from("usage_events").insert({
      user_id: userId,
      brand_id: brand.id,
      kind: "plan_import",
      units: rows.length,
      cost_cents: 0,
      ref_table: "content_plans",
      ref_id: plan.id,
    }).then(() => {}, () => {});

    return json({
      plan_id: plan.id,
      title: plan.title,
      starts_on: plan.starts_on,
      days: plan.days,
      posts_per_day: plan.posts_per_day,
      planned: rows.length,
      dropped: skipped,
      slots: (slots ?? []).length,
      found: posts.length,
      imported: true,
      model: MODEL,
      tokens,
    });
  } catch (error) {
    return fail(error);
  }
});

// ------------------------------------------------------------------ reading

async function readAny(bytes: Uint8Array, name: string): Promise<string> {
  const lower = name.toLowerCase();
  const isZip = bytes[0] === 0x50 && bytes[1] === 0x4b;
  const isPdf = bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;

  if (isPdf || lower.endsWith(".pdf")) return await readPdf(bytes);
  if (isZip) {
    const files = unzipped(bytes);
    if (files["word/document.xml"]) return docxText(files);
    // A ZIP of documents: every readable file, in name order.
    const parts: string[] = [];
    for (const key of Object.keys(files).sort()) {
      const k = key.toLowerCase();
      if (k.startsWith("__macosx/") || k.endsWith("/")) continue;
      const data = files[key];
      try {
        if (k.endsWith(".docx")) parts.push(`# ${key}\n${docxText(unzipped(data))}`);
        else if (k.endsWith(".pdf")) parts.push(`# ${key}\n${await readPdf(data)}`);
        else if (/\.(txt|md|markdown|csv|json|html?)$/.test(k)) parts.push(`# ${key}\n${plain(strFromU8(data), k)}`);
      } catch (error) {
        console.error("zip entry", key, error);
      }
    }
    return parts.join("\n\n");
  }
  return plain(new TextDecoder().decode(bytes), lower);
}

/** Entries keyed with forward slashes: Windows tools write `word\document.xml`. */
function unzipped(bytes: Uint8Array): Record<string, Uint8Array> {
  const files = unzipSync(bytes);
  return Object.fromEntries(Object.entries(files).map(([key, data]) => [key.replace(/\\/g, "/"), data]));
}

async function readPdf(bytes: Uint8Array): Promise<string> {
  const pdf = await getDocumentProxy(new Uint8Array(bytes));
  const { text } = await extractText(pdf, { mergePages: true });
  return Array.isArray(text) ? text.join("\n") : String(text ?? "");
}

function docxText(files: Record<string, Uint8Array>): string {
  const xml = strFromU8(files["word/document.xml"]);
  return decodeEntities(
    xml
      .replace(/<w:tab\/>/g, "\t")
      .replace(/<w:br[^>]*\/>/g, "\n")
      .replace(/<\/w:p>/g, "\n")
      .replace(/<\/w:tc>/g, " | ")
      .replace(/<[^>]+>/g, ""),
  );
}

function plain(text: string, name: string): string {
  if (/\.html?$/.test(name)) {
    return decodeEntities(text.replace(/<(script|style)[\s\S]*?<\/\1>/gi, "").replace(/<br\s*\/?>|<\/(p|div|li|h\d|tr)>/gi, "\n").replace(/<[^>]+>/g, ""));
  }
  return text;
}

function decodeEntities(text: string): string {
  return text
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&amp;/g, "&");
}

// --------------------------------------------------------------- extracting

async function extract(piece: string, already: number, today: string): Promise<{ title: string; objective: string; posts: Found[]; tokens: number }> {
  const system = [
    "You read a content plan somebody wrote and list the posts that are in it.",
    'Return JSON only: {"title":string,"posts":[{"day":number|null,"date":"YYYY-MM-DD"|null,"time":"HH:MM"|null,"hook":string,"caption":string,"concept":string,"hashtags":[string],"cta":string,"format":"video"|"photo"|"carousel"}]}.',
    "One entry per post the document describes, in document order. Several posts on one day are separate entries with the same day.",
    "day: the day number the document gives (Day 1, D3, #5). null if it gives none.",
    `date: only if the document states a calendar date (e.g. "Monday Sep 21"). Never invent one. Today is ${today}; a date written without a year is its next occurrence on or after today. time: only if the document states a time; 24-hour (7:00 PM is 19:00).`,
    "hook: the post's title, hook or opening line, as written. caption: its caption or on-screen text, as written. concept: what the video shows or the script, as written, shortened to at most 3 sentences.",
    "Copy the document's words. NEVER add posts, ideas, facts, numbers or hashtags that are not in the document. Leave a field empty rather than make it up.",
    "Ignore anything that is not a post: introductions, strategy notes, goals, tips.",
    "title: the plan's own title if it has one, else empty.",
    "objective: the plan's stated goal, as written, if it states one, else empty. Add \"objective\":string to the top level of the JSON.",
    "cta: the post's call to action as written (e.g. \"Link in bio\"), else empty. hashtags: the post's hashtags as written.",
    already > 0 ? `This is a later part of the same document; ${already} posts were already listed from earlier parts. Keep the document's own day numbers.` : "",
  ].filter(Boolean).join("\n");

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: MODEL,
      temperature: 0,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: system },
        { role: "user", content: `DOCUMENT:\n${piece}` },
      ],
    }),
  });
  const completion = await response.json();
  if (!response.ok) {
    console.error("openai", completion?.error);
    throw new PublicError("The reader could not be reached just now.", 502);
  }
  try {
    const parsed = JSON.parse(completion.choices?.[0]?.message?.content ?? "{}");
    return {
      title: typeof parsed.title === "string" ? parsed.title.trim() : "",
      objective: typeof parsed.objective === "string" ? parsed.objective.trim() : "",
      posts: Array.isArray(parsed.posts) ? parsed.posts : [],
      tokens: completion.usage?.total_tokens ?? 0,
    };
  } catch {
    console.error("unparseable extraction");
    return { title: "", objective: "", posts: [], tokens: completion.usage?.total_tokens ?? 0 };
  }
}

// -------------------------------------------------------------------- dates

function validDate(value?: string | null): value is string {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(Date.parse(value));
}

function addDays(date: string, days: number): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + days * 86_400_000).toISOString().slice(0, 10);
}

function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(b) - Date.parse(a)) / 86_400_000);
}

function parseTime(value?: string | null): { h: number; m: number } | null {
  const match = /^(\d{1,2}):(\d{2})$/.exec((value ?? "").trim());
  if (!match) return null;
  const h = Number(match[1]);
  const m = Number(match[2]);
  return h < 24 && m < 60 ? { h, m } : null;
}

function todayIn(timezone: string): string {
  return localDate(new Date().toISOString(), timezone);
}

function localDate(iso: string, timezone: string): string {
  try {
    return new Intl.DateTimeFormat("en-CA", { timeZone: timezone, year: "numeric", month: "2-digit", day: "2-digit" })
      .format(new Date(iso));
  } catch {
    return iso.slice(0, 10);
  }
}

/** A wall-clock time in a zone, as a UTC ISO string. */
function zonedToUtc(date: string, h: number, m: number, timezone: string): string | null {
  const [y, mo, d] = date.split("-").map(Number);
  const guess = Date.UTC(y, mo - 1, d, h, m);
  try {
    const parts = Object.fromEntries(
      new Intl.DateTimeFormat("en-US", {
        timeZone: timezone, hourCycle: "h23",
        year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
      }).formatToParts(new Date(guess)).map((p) => [p.type, p.value]),
    );
    const asLocal = Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day), Number(parts.hour), Number(parts.minute));
    return new Date(guess - (asLocal - guess)).toISOString();
  } catch {
    return null;
  }
}
