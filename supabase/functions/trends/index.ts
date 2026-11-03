/**
 * "Trending today" for the Explore tab (Abel, 3 Nov 2026).
 *
 * Looked up on the web once a day per country and kept in `daily_trends`, so
 * everyone in a country shares one search. Returns `{ items: [{ kind, title,
 * why, idea }] }`; an empty list when nothing could be found, never an error
 * the app has to show.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { fail, json, preflight } from "../_shared/http.ts";
import { MODELS } from "../_shared/route.ts";
import { recordUsage } from "../_shared/usage.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY") ?? "";

interface Trend {
  kind: string;
  title: string;
  why: string;
  idea: string;
}

const KINDS = ["Sound", "Format", "Challenge", "Topic"];

function today(zone: string): string {
  try {
    return new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit" })
      .format(new Date());
  } catch {
    return new Date().toISOString().slice(0, 10);
  }
}

/** The model's JSON, read leniently: fenced or not, a list or under `items`. */
function readTrends(text: string): Trend[] {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end <= start) return [];
  try {
    const parsed = JSON.parse(text.slice(start, end + 1));
    const list = Array.isArray(parsed?.items) ? parsed.items : [];
    return list
      .map((item: Record<string, unknown>) => ({
        kind: KINDS.includes(String(item.kind)) ? String(item.kind) : "Format",
        title: String(item.title ?? "").replace(/\s*\(\[.*$/, "").trim().slice(0, 80),
        why: String(item.why ?? "").replace(/\s*\(\[[^\]]*\]\([^)]*\)\)/g, "").trim().slice(0, 200),
        idea: String(item.idea ?? "").replace(/\s*\(\[[^\]]*\]\([^)]*\)\)/g, "").trim().slice(0, 240),
      }))
      .filter((item: Trend) => item.title && item.why)
      .slice(0, 8);
  } catch {
    return [];
  }
}

async function lookUp(region: string, zone: string, onUsage: (usage: unknown, searches: number) => Promise<void>): Promise<Trend[]> {
  if (!OPENAI_KEY) return [];
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: MODELS.web,
      reasoning: { effort: "low" },
      tools: [{ type: "web_search", user_location: { type: "approximate", country: region, timezone: zone } }],
      tool_choice: "required",
      instructions: [
        `Today is ${today(zone)}. Search the web for what is trending RIGHT NOW for short-form creators on TikTok, Instagram Reels and YouTube Shorts, for an audience in ${region} (and worldwide where that matters).`,
        "Find 6 things a creator could post about today: trending sounds, video formats, challenges and topics people are making videos about. Only things that are current this week; nothing from earlier years.",
        'JSON only, no other text: {"items":[{"kind":"Sound|Format|Challenge|Topic","title":"short name, under 6 words","why":"one plain sentence on why it is moving now","idea":"one plain sentence on a video a creator could make with it"}]}',
        "No links, no citations, no markdown.",
      ].join("\n"),
      input: "What is trending for creators today?",
    }),
  });
  if (!response.ok) {
    console.error("trends", response.status, (await response.text().catch(() => "")).slice(0, 300));
    return [];
  }
  const body = await response.json();
  let text = "";
  let searches = 0;
  for (const item of body.output ?? []) {
    if (item.type === "web_search_call") searches += 1;
    if (item.type === "message") {
      for (const part of item.content ?? []) if (part.type === "output_text") text += part.text;
    }
  }
  await onUsage(body.usage, searches).catch(() => {});
  return readTrends(text);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  try {
    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: request.headers.get("Authorization") ?? "" } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) return json({ error: "Sign in first." }, 401);

    const body = await request.json().catch(() => ({})) as { region?: string; timezone?: string };
    const region = typeof body.region === "string" && /^[A-Z]{2}$/.test(body.region) ? body.region : "US";
    const zone = typeof body.timezone === "string" && body.timezone.length < 64 ? body.timezone : "UTC";
    const day = today(zone);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: cached } = await admin.from("daily_trends").select("items").eq("day", day).eq("region", region).maybeSingle();
    if (cached?.items) return json({ items: cached.items });

    const items = await lookUp(region, zone, async (usage, searches) => {
      const used = usage as { input_tokens?: number; output_tokens?: number; input_tokens_details?: { cached_tokens?: number } } | null;
      await recordUsage(admin, {
        userId: auth.user!.id,
        kind: "trends",
        model: MODELS.web,
        usage: used
          ? { prompt_tokens: used.input_tokens, completion_tokens: used.output_tokens, prompt_tokens_details: { cached_tokens: used.input_tokens_details?.cached_tokens ?? 0 } }
          : null,
        searches,
      });
    });
    if (items.length > 0) {
      await admin.from("daily_trends").upsert({ day, region, items }, { onConflict: "day,region", ignoreDuplicates: true });
    }
    return json({ items });
  } catch (error) {
    return fail(error);
  }
});
