/**
 * Ideas for the next video, drawn from the videos this account already made.
 *
 * Abel, 25 Sep 2026: "depending on the kind of videos the user makes, the
 * captions, the hashtags -- understand what videos he's making and give the
 * user inspirational videos to post, like VidIQ."
 *
 * WHAT MAKES THIS DIFFERENT FROM A TREND FEED. VidIQ and its like show what is
 * working on the platform. Autocast can see something nobody else can: what is
 * working on THIS account. `_shared/learning.ts` already turns the account's
 * own posts into findings -- "videos under 20 seconds get 2.4x the views on
 * this account, over 14 posts" -- and those findings are sitting in `insights`
 * being used for nothing a person looks at. An idea here is a hook plus the
 * measured sentence behind it, so the suggestion can be judged rather than
 * believed.
 *
 * THE HONESTY RULE. A new account has no numbers and the feed still has to say
 * something. Those ideas come from the pillars and the style the person chose,
 * and they are written to the table with `measured = false`, so the app can
 * label them a starting point. The one thing this must never do is state an
 * audience finding the account has not earned -- the exact failure that made
 * the planner announce features Remi does not have. So:
 *
 *   - every idea must name one of the supplied insight keys, or be marked
 *     unmeasured; an idea citing a key that was not supplied is dropped
 *   - `because` is quoted from the insight's own statement, never rewritten
 *   - no numbers, people, quotes or dates may appear in the hook or the angle
 *
 * Read-and-write: it computes, upserts by key so a refresh updates an idea
 * instead of duplicating it, and returns the feed.
 */

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { fail, json, preflight, PublicError } from "../_shared/http.ts";
import { recordUsage } from "../_shared/usage.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");
const MODEL = Deno.env.get("PLANNER_MODEL") ?? Deno.env.get("LLM_MODEL") ?? "gpt-4.1-nano";

/** How many to ask for. One screenful of cards, and no more billing than that. */
const WANTED = 6;

/** How long a computed feed stands before it is worth paying to redo. */
const FRESH_FOR_HOURS = 20;

interface Body {
  brand_id?: string;
  /** Recompute even if the feed is fresh -- pull to refresh. */
  force?: boolean;
}

interface LearningRow {
  video_id: string;
  platform: string;
  description: string | null;
  duration_s: number | null;
  views: number;
  format: string | null;
  pillar: string | null;
}

interface Insight {
  key: string;
  statement: string;
  lift: number;
  sample_size: number;
  confidence: string;
}

interface Idea {
  key?: string;
  hook?: string;
  angle?: string;
  insight_key?: string;
  seconds?: number;
  format?: string;
  hashtags?: string[];
}

// ------------------------------------------------------------------ reading

/** The hashtags this account actually uses, commonest first. */
function hashtagsIn(rows: LearningRow[]): string[] {
  const seen = new Map<string, number>();
  for (const row of rows) {
    for (const tag of (row.description ?? "").match(/#[\p{L}\p{N}_]+/gu) ?? []) {
      const key = tag.toLowerCase();
      seen.set(key, (seen.get(key) ?? 0) + 1);
    }
  }
  return [...seen.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12).map(([tag]) => tag);
}

/**
 * The account in one paragraph of facts, and nothing that is not a fact.
 *
 * Everything here came out of `learning_input`, which reads posts that really
 * went out and metrics that really came back. No adjectives, no summary of how
 * the account is "doing" -- the model gets numbers and writes hooks.
 */
function accountFacts(rows: LearningRow[]): string[] {
  if (rows.length === 0) return [];
  const lines: string[] = [`${rows.length} posts with numbers on them.`];

  const byViews = [...rows].sort((a, b) => b.views - a.views);
  const best = byViews.slice(0, 5).filter((r) => r.views > 0);
  if (best.length > 0) {
    lines.push("Their best posts, most viewed first:");
    for (const row of best) {
      const words = (row.description ?? "").replace(/#[\p{L}\p{N}_]+/gu, "").trim().slice(0, 120);
      const seconds = row.duration_s ? `${Math.round(row.duration_s)}s` : "length unknown";
      lines.push(`- ${row.views} views, ${seconds}${row.pillar ? `, theme ${row.pillar}` : ""}: ${words || "(no caption)"}`);
    }
  }

  const themes = [...new Set(rows.map((r) => r.pillar).filter((p): p is string => !!p))];
  if (themes.length > 0) lines.push(`Themes they post under: ${themes.join(", ")}.`);

  const formats = [...new Set(rows.map((r) => r.format).filter((f): f is string => !!f))];
  if (formats.length > 0) lines.push(`Formats they use: ${formats.join(", ")}.`);

  const lengths = rows.map((r) => r.duration_s).filter((d): d is number => typeof d === "number" && d > 0);
  if (lengths.length > 0) {
    lines.push(`Lengths they post, shortest to longest: ${Math.round(Math.min(...lengths))}s to ${Math.round(Math.max(...lengths))}s.`);
  }

  const tags = hashtagsIn(rows);
  if (tags.length > 0) lines.push(`Hashtags they use: ${tags.join(" ")}.`);

  return lines;
}

// ------------------------------------------------------------------ writing

/**
 * What the model may and may not do.
 *
 * The prohibitions are the same ones the planner needed and for the same
 * reason: given a paragraph about a brand it will cheerfully invent a
 * milestone, a customer or a percentage, and a feed that says "your audience
 * loves X" when nothing measured X is worse than no feed.
 */
function systemPrompt(measured: boolean): string {
  return [
    "You suggest short-form videos for one creator to make next. You are given facts about their own posts. You write ideas, not analysis.",
    "Return JSON: {\"ideas\":[{\"key\":\"short-slug\",\"hook\":\"...\",\"angle\":\"...\",\"insight_key\":\"...\",\"seconds\":20,\"format\":\"...\",\"hashtags\":[\"#x\"]}]}.",
    `Exactly ${WANTED} ideas. Every one must be different from the others and from anything in the list of what they have already posted.`,
    "hook: the first line of the video, said out loud, under 90 characters. angle: one sentence on what the rest of the video shows.",
    // 🔴 Asked for "format" without saying what one is and got back
    // "visual demonstration with close-ups of c" -- a sentence, cut off by
    // the column. It is a label on a card, not a description.
    "format: ONE OR TWO WORDS naming the shape of the video, like \"demo\", \"talking head\", \"voiceover\", \"screen recording\", \"before and after\". Never a sentence.",
    "hashtags: three to five, each starting with #. Prefer the ones this account already uses.",
    measured
      ? "insight_key: the key of the ONE supplied insight this idea follows. Only the keys listed under INSIGHTS may be used. An idea that does not follow one of them must not be returned."
      : "insight_key: use \"pillar\" -- there are no measured insights for this account yet.",
    "seconds: a whole number of seconds between 8 and 90, chosen to suit the idea.",
    "NEVER invent a number, a price, a date, a rating, a milestone, or a person. NEVER write a quote, a testimonial, or \"one viewer said\". You have never met this account's audience.",
    "Never claim speed, accuracy, or being the best. Avoid hype: no \"game changer\", \"secret\", \"hack\", \"ultimate\", \"insane\", \"easy\".",
    "Do not describe what the creator's results have been -- that sentence is written elsewhere from the measured insight. Write the video.",
  ].join("\n");
}

async function write(
  facts: string[],
  insights: Insight[],
  avoid: string[],
): Promise<{ ideas: Idea[]; usage: { prompt_tokens: number; completion_tokens: number } }> {
  const measured = insights.length > 0;
  const parts = ["ABOUT THIS ACCOUNT:", ...facts];
  if (measured) {
    parts.push("", "INSIGHTS measured on this account. Use the key, follow the finding:");
    for (const insight of insights) {
      parts.push(`- ${insight.key}: ${insight.statement} (${insight.sample_size} posts, ${insight.confidence} confidence)`);
    }
  }
  if (avoid.length > 0) {
    parts.push("", "Already posted or already suggested, do not repeat or paraphrase:");
    for (const line of avoid) parts.push(`- ${line}`);
  }

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: MODEL,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: systemPrompt(measured) },
        { role: "user", content: parts.join("\n") },
      ],
    }),
  });

  const completion = await response.json();
  if (!response.ok) {
    console.error("openai", completion?.error);
    throw new PublicError("Ideas could not be written just now.", 502);
  }

  let ideas: Idea[] = [];
  try {
    const parsed = JSON.parse(completion.choices?.[0]?.message?.content ?? "{}");
    ideas = Array.isArray(parsed.ideas) ? parsed.ideas : [];
  } catch {
    console.error("unparseable ideas");
  }

  return {
    ideas,
    usage: {
      prompt_tokens: completion.usage?.prompt_tokens ?? 0,
      completion_tokens: completion.usage?.completion_tokens ?? 0,
    },
  };
}

/** A person where none was given: the one invention the prompt does not stop. */
const INVENTS_A_PERSON = /\b(one (?:of my )?(?:viewer|user|customer|client|follower)s?|a (?:viewer|user|customer|client) (?:told|said|asked|wrote)|testimonial|dm(?:'?d| me))\b/i;
/** A figure nobody supplied: "3x", "90%", "$40", "10,000 followers". */
const INVENTS_A_NUMBER = /(\d+\s*x\b|\d+\s*%|[$£€]\s*\d|\b\d{3,}\b)/;

/**
 * A short label, or nothing at all.
 *
 * The card has room for two words beside the length. Anything longer is the
 * model having written a description where a label was asked for, and a
 * description cut at 40 characters reads as a bug -- which is exactly how it
 * first shipped to the probe.
 */
function label(text: unknown): string | null {
  if (typeof text !== "string") return null;
  const trimmed = text.trim().replace(/\.$/, "");
  if (!trimmed || trimmed.length > 24 || trimmed.split(/\s+/).length > 3) return null;
  return trimmed;
}

function slug(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60);
}

// -------------------------------------------------------------------- serve

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);
    const asUser = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authorization } } });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const body = (await request.json().catch(() => ({}))) as Body;

    // Read the brand under RLS, so a caller cannot ask for ideas about
    // somebody else's account.
    const brandQuery = asUser.from("brands").select("id, name, niche, audience");
    const { data: brand } = await (
      typeof body.brand_id === "string" && body.brand_id.length === 36
        ? brandQuery.eq("id", body.brand_id)
        : brandQuery.order("created_at", { ascending: true })
    ).limit(1).maybeSingle();
    if (!brand) throw new PublicError("Set up your brand first.", 400);

    const admin: SupabaseClient = createClient(SUPABASE_URL, SERVICE_KEY);

    const { data: standing } = await admin
      .from("inspiration_ideas")
      .select("id, key, hook, angle, because, measured, seconds, format, hashtags, status, computed_at")
      .eq("brand_id", brand.id)
      .order("computed_at", { ascending: false })
      .limit(40);
    const existing = standing ?? [];
    const feed = existing.filter((row) => row.status === "new");

    // Fresh enough, and there is something to show: hand it back without
    // paying a model to rewrite what is already on the screen.
    const newest = feed[0]?.computed_at ? new Date(feed[0].computed_at).getTime() : 0;
    const fresh = Date.now() - newest < FRESH_FOR_HOURS * 60 * 60 * 1000;
    if (!body.force && fresh && feed.length >= 3) {
      return json({ ideas: feed, computed: false });
    }

    if (!OPENAI_KEY) {
      // No writer configured is not a reason to blank a feed that exists.
      if (feed.length > 0) return json({ ideas: feed, computed: false });
      throw new PublicError("The writer is not configured yet.", 503);
    }

    const { data: rawRows } = await admin.rpc("learning_input", { p_brand: brand.id });
    const rows = ((rawRows ?? []) as LearningRow[]).map((r) => ({ ...r, views: Number(r.views ?? 0) }));

    const { data: rawInsights } = await admin
      .from("insights")
      .select("key, statement, lift, sample_size, confidence")
      .eq("brand_id", brand.id)
      .eq("status", "active");
    const insights = (rawInsights ?? []) as Insight[];
    const byKey = new Map(insights.map((i) => [i.key, i]));

    const facts = accountFacts(rows);
    if (facts.length === 0) {
      // Nothing posted yet. The pillars and the brand are all there is, and
      // the ideas that come out of them are marked unmeasured.
      const { data: pillars } = await admin
        .from("content_pillars")
        .select("name, description")
        .eq("brand_id", brand.id);
      facts.push(`${brand.name} posts about ${brand.niche ?? "its own subject"}.`);
      if (brand.audience) facts.push(`Their audience: ${brand.audience}.`);
      for (const pillar of (pillars ?? []) as Array<{ name: string; description: string | null }>) {
        facts.push(`- theme: ${pillar.name}${pillar.description ? ` -- ${pillar.description}` : ""}`);
      }
      facts.push("They have not posted anything with numbers on it yet.");
    }

    // What not to write again: what they posted, and what was suggested and
    // dismissed. A dismissed idea coming back next morning is the fastest way
    // to make a feed worth ignoring.
    const avoid = [
      ...rows.slice(0, 20).map((r) => (r.description ?? "").slice(0, 90)).filter(Boolean),
      ...existing.map((row) => row.hook as string),
    ].slice(0, 40);

    const { ideas: written, usage } = await write(facts, insights, avoid);
    await recordUsage(admin, {
      userId: auth.user.id,
      brandId: brand.id,
      kind: "inspiration",
      model: MODEL,
      usage,
    });

    const hidden = new Set(existing.filter((r) => r.status === "hidden").map((r) => r.key as string));
    const kept: Array<Record<string, unknown>> = [];
    let dropped = 0;

    for (const idea of written) {
      const hook = (idea.hook ?? "").trim();
      const angle = (idea.angle ?? "").trim();
      if (!hook || !angle) { dropped += 1; continue; }

      const text = `${hook} ${angle}`;
      if (INVENTS_A_PERSON.test(text) || INVENTS_A_NUMBER.test(text)) { dropped += 1; continue; }

      // The measured sentence is the insight's OWN words. The model is never
      // asked to restate a finding, because a restated finding is a finding
      // with a new number in it.
      const insight = idea.insight_key ? byKey.get(idea.insight_key) : undefined;
      if (insights.length > 0 && !insight) { dropped += 1; continue; }

      const key = slug(idea.key || hook);
      if (!key || hidden.has(key)) { dropped += 1; continue; }

      kept.push({
        user_id: auth.user.id,
        brand_id: brand.id,
        key,
        hook: hook.slice(0, 200),
        angle: angle.slice(0, 400),
        because: insight
          ? insight.statement
          : "A starting point from the themes you chose. Post a few and this turns into what your own numbers say.",
        evidence: insight
          ? { insight_key: insight.key, lift: insight.lift, sample_size: insight.sample_size, confidence: insight.confidence }
          : {},
        measured: !!insight,
        seconds: Number.isFinite(idea.seconds) ? Math.min(90, Math.max(8, Math.round(idea.seconds as number))) : null,
        // A label, or nothing. Truncating a sentence to fit the column is how
        // "visual demonstration with close-ups of c" ended up on a card.
        format: label(idea.format),
        hashtags: Array.isArray(idea.hashtags)
          ? idea.hashtags.filter((t) => typeof t === "string").map((t) => t.trim()).filter(Boolean).slice(0, 8)
          : [],
        status: "new",
        computed_at: new Date().toISOString(),
      });
    }

    if (kept.length > 0) {
      const { error } = await admin
        .from("inspiration_ideas")
        .upsert(kept, { onConflict: "brand_id,key" });
      if (error) console.error("inspiration upsert", error.message);
    }

    const { data: after } = await admin
      .from("inspiration_ideas")
      .select("id, key, hook, angle, because, measured, seconds, format, hashtags, status, computed_at")
      .eq("brand_id", brand.id)
      .eq("status", "new")
      .order("computed_at", { ascending: false })
      .limit(12);

    return json({
      ideas: after ?? [],
      computed: true,
      // Reported rather than hidden. Four ideas out of six asked for is a fact
      // worth seeing in the logs when the prompt starts drifting.
      dropped,
      measured: insights.length > 0,
    });
  } catch (error) {
    return fail(error);
  }
});
