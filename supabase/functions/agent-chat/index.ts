/**
 * The agent, in its first useful form.
 *
 * You describe what you want and it comes back with post ideas written for your
 * brand: a hook, a caption, and one line saying why it chose that. The ideas are
 * returned as structured rows rather than prose, so the app can offer to put
 * them straight into the queue instead of making you retype anything.
 *
 * What it deliberately cannot do: publish, approve, or grant rights. It writes
 * words. Everything that reaches TikTok still goes through the approval sheet.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");

/** Cheapest model that answers without a reasoning tax. Overridable without a
 *  redeploy, because the cheapest option changes every few months. */
const MODEL = Deno.env.get("LLM_MODEL") ?? "gpt-4.1-nano";

interface Body {
  message?: string;
  count?: number;
}

interface Idea {
  hook: string;
  caption: string;
  hashtags: string[];
  rationale: string;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    if (!OPENAI_KEY) throw new PublicError("The writer is not configured yet.", 503);

    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);

    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const body = (await request.json().catch(() => ({}))) as Body;
    const message = (body.message ?? "").trim();
    if (!message) throw new PublicError("Say what you want it to make.");

    const count = Math.min(Math.max(body.count ?? 3, 1), 5);

    // The brief, read under RLS. Without it the writing is generic, which is
    // the whole reason the brand fields exist.
    const { data: brand } = await asUser
      .from("brands")
      .select("name, niche, audience")
      .limit(1)
      .maybeSingle();

    // What it has already written, so it does not repeat itself.
    const { data: recent } = await asUser
      .from("posts")
      .select("hook")
      .order("created_at", { ascending: false })
      .limit(15);

    const previous = (recent ?? []).map((row: { hook: string }) => row.hook).filter(Boolean);

    const system = [
      "You write short-form video ideas for one social account.",
      "Return JSON only, matching: {\"ideas\":[{\"hook\":string,\"caption\":string,\"hashtags\":[string],\"rationale\":string}]}.",
      "hook: the first line said on camera, under 80 characters, concrete and specific.",
      "caption: what goes under the video, under 150 characters.",
      "hashtags: 2 to 4, lowercase, no spaces, each starting with #.",
      "rationale: one sentence, in your own words, saying why this idea suits this account. Never say it will do well.",
      "Avoid hype words. Avoid the word easy. Prefer a specific number or a specific cost over a general claim.",
    ].join("\n");

    const brief = brand
      ? `Account: ${brand.name}. Subject: ${brand.niche || "not stated"}. Audience: ${brand.audience || "not stated"}.`
      : "The account has not described itself yet, so keep the ideas broadly useful.";

    const avoid = previous.length > 0
      ? `Already used, do not repeat these openings:\n${previous.map((h) => `- ${h}`).join("\n")}`
      : "";

    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${OPENAI_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: MODEL,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: system },
          { role: "user", content: `${brief}\n\n${avoid}\n\nAsked for: ${message}\n\nGive exactly ${count} ideas.` },
        ],
      }),
    });

    const completion = await response.json();

    if (!response.ok) {
      console.error("openai", completion?.error);
      throw new PublicError("The writer could not be reached just now.", 502);
    }

    const raw = completion.choices?.[0]?.message?.content ?? "{}";
    let ideas: Idea[] = [];
    try {
      const parsed = JSON.parse(raw) as { ideas?: Idea[] };
      ideas = (parsed.ideas ?? []).filter(
        (idea) => typeof idea?.hook === "string" && idea.hook.trim().length > 0,
      );
    } catch {
      throw new PublicError("The writer returned something unreadable. Try again.", 502);
    }

    if (ideas.length === 0) throw new PublicError("Nothing usable came back. Try rephrasing.");

    return json({
      ideas: ideas.slice(0, count).map((idea) => ({
        hook: idea.hook,
        caption: idea.caption ?? "",
        hashtags: Array.isArray(idea.hashtags) ? idea.hashtags.slice(0, 4) : [],
        rationale: idea.rationale ?? "",
      })),
      model: MODEL,
      tokens: completion.usage?.total_tokens ?? 0,
    });
  } catch (error) {
    return fail(error);
  }
});
