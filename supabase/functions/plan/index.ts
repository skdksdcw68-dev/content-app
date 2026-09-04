// Autocast's planner. This is the part that decides.
//
// The provider key lives here, in Supabase's secret store, and never reaches
// the iOS app -- anyone can pull strings out of an .ipa, so a key shipped in
// the binary is a published key. Same position as Maily's ai function.
//
// Two callers, one job:
//   a user JWT      plan for that person now. RLS does the scoping, so this
//                   path cannot read or write anyone else's queue.
//   the service key plus {"sweep": true}, to run every autopilot on a cron.
//
// Only the WRITING goes to a model. Which pillar comes next is weighted
// arithmetic over what is already queued, and a model asked to do arithmetic
// is slower, costlier and less predictable than the arithmetic.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Writing in someone's voice, to an audience who will scroll past anything
// that sounds generic, is the whole product -- so this is the quality tier,
// the same one Maily drafts replies with. There is no cheap-tier job here:
// pillar selection is arithmetic, not a model call.
const WRITE_MODEL = "gpt-5.6-luna";

/// Spoken words per minute, for turning a script into a duration before
/// anything is rendered. A script that overruns fails at render time, which
/// is late and wasteful -- the sample data carries a failed post for exactly
/// this reason.
const WORDS_PER_MINUTE = 150;

/// Hard ceilings the platforms enforce. Mirrors Platform.maxDuration in the
/// app; if one changes, both change.
const MAX_DURATION: Record<string, number> = {
  tiktok: 180,
  reels: 90,
  shorts: 60,
};

/// How far ahead the planner is willing to fill. Beyond this it is guessing
/// about a week it knows nothing about yet.
const HORIZON_DAYS = 3;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// ------------------------------------------------------------------- types

interface Settings {
  user_id: string;
  is_on: boolean;
  posts_per_day: number;
  platforms: string[];
  tone: string;
  requires_approval: boolean;
  quiet_hours_start: number;
  quiet_hours_end: number;
}

interface Pillar {
  id: string;
  name: string;
  detail: string;
  weight: number;
  is_enabled: boolean;
}

interface Post {
  id: string;
  hook: string;
  pillar_id: string | null;
  status: string;
  scheduled_for: string | null;
  created_at: string;
}

interface Draft {
  hook: string;
  script: string;
  caption: string;
  hashtags: string[];
  rationale: string;
}

// ------------------------------------------------------------------ timing

/// True when `hour` falls inside the quiet window. The window wraps past
/// midnight whenever start > end, which is the normal case. Mirrors
/// AutopilotSettings.isQuiet in the app.
function isQuiet(settings: Settings, hour: number): boolean {
  const { quiet_hours_start: start, quiet_hours_end: end } = settings;
  if (start === end) return false;
  if (start < end) return hour >= start && hour < end;
  return hour >= start || hour < end;
}

/// The next slot at or after `from` that is outside quiet hours and not
/// already taken. Walks hour by hour rather than computing a closed form,
/// because the quiet window wraps and the taken-set is sparse -- a loop over
/// at most a few days of hours is clearer and fast enough.
function nextSlot(settings: Settings, from: Date, taken: Set<number>): Date | null {
  const spacingHours = Math.max(1, Math.floor(24 / Math.max(1, settings.posts_per_day)));
  const cursor = new Date(from);
  cursor.setUTCMinutes(0, 0, 0);

  for (let step = 0; step < HORIZON_DAYS * 24; step++) {
    cursor.setUTCHours(cursor.getUTCHours() + 1);
    if (isQuiet(settings, cursor.getUTCHours())) continue;

    // Keep slots apart, so a day's posts are spread rather than stacked.
    const clashes = [...taken].some(
      (t) => Math.abs(t - cursor.getTime()) < spacingHours * 3600_000
    );
    if (clashes) continue;

    return new Date(cursor);
  }
  return null;
}

// ---------------------------------------------------------- pillar choice

/// Picks the pillar that is furthest behind its share.
///
/// Each enabled pillar has a target share of the queue equal to its weight
/// over the total weight. Whichever has the largest shortfall against that
/// target goes next, so a pillar weighted 3 gets planned three times as often
/// as one weighted 1 without any randomness to be unlucky with.
function choosePillar(pillars: Pillar[], recent: Post[]): Pillar | null {
  const enabled = pillars.filter((p) => p.is_enabled && p.weight > 0);
  if (enabled.length === 0) return null;

  const totalWeight = enabled.reduce((sum, p) => sum + p.weight, 0);
  const counts = new Map<string, number>();
  for (const post of recent) {
    if (post.pillar_id) counts.set(post.pillar_id, (counts.get(post.pillar_id) ?? 0) + 1);
  }
  const totalPosts = recent.length || 1;

  let best = enabled[0];
  let worstShortfall = -Infinity;
  for (const pillar of enabled) {
    const share = (counts.get(pillar.id) ?? 0) / totalPosts;
    const target = pillar.weight / totalWeight;
    const shortfall = target - share;
    if (shortfall > worstShortfall) {
      worstShortfall = shortfall;
      best = pillar;
    }
  }
  return best;
}

// ------------------------------------------------------------------ writing

const SYSTEM = `You write short-form video for one person's own account.

Return JSON only, no prose:
{
  "hook": "the first line said on camera, under 12 words",
  "script": "the whole thing said aloud, first person",
  "caption": "one line under the video, under 15 words",
  "hashtags": ["#three", "#at", "#most"],
  "rationale": "why THIS, now, in one sentence addressed to the account owner"
}

The rationale is not marketing copy and not a summary of the script. It is your
reasoning, shown to the person so they can disagree with it. Tie it to
something concrete: a pillar that is behind, a post that did well, a question
that keeps coming up. "This will perform well" is a non-answer and is worse
than saying nothing.

The script is spoken, so write it to be said, not read. No headings, no bullet
points, no stage directions, no "in this video". Start at the hook and keep
going. Short sentences. Concrete over abstract: one real detail beats three
adjectives.

Do not invent facts about the account owner, their numbers, or their customers.
You may only use what is given to you. If a pillar asks for something you have
not been told, write about the pillar's subject generally rather than making up
a specific.`;

async function write(
  pillar: Pillar,
  settings: Settings,
  platform: string,
  recent: Post[]
): Promise<Draft> {
  const maxSeconds = MAX_DURATION[platform] ?? 60;
  // Leave headroom: aim at 80% of the ceiling so a slightly long delivery
  // still fits, rather than failing at render for three seconds.
  const wordBudget = Math.floor((maxSeconds * 0.8 * WORDS_PER_MINUTE) / 60);

  const alreadySaid = recent
    .slice(0, 15)
    .map((p) => `- ${p.hook}`)
    .join("\n");

  const user = `Pillar: ${pillar.name}
What that pillar means: ${pillar.detail}

Platform: ${platform}, hard limit ${maxSeconds} seconds spoken.
Keep the script at or under ${wordBudget} words.

Voice: ${settings.tone || "plain and direct"}

Already planned or posted -- do not repeat these, and do not write a near-miss
of one:
${alreadySaid || "(nothing yet -- this is the first post)"}`;

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENAI_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: WRITE_MODEL,
      messages: [
        { role: "system", content: SYSTEM },
        { role: "user", content: user },
      ],
      response_format: { type: "json_object" },
    }),
  });

  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload?.error?.message ?? `provider returned ${response.status}`);
  }

  const draft = JSON.parse(payload.choices[0].message.content) as Draft;

  // Trust nothing about length. The model was asked for a word budget, which
  // is guidance, not a guarantee -- and an overrun is only discovered at
  // render time otherwise, after the money is spent.
  const words = draft.script.trim().split(/\s+/).length;
  const seconds = (words / WORDS_PER_MINUTE) * 60;
  if (seconds > maxSeconds) {
    throw new Error(
      `script runs ~${Math.round(seconds)}s, over ${platform}'s ${maxSeconds}s limit`
    );
  }
  if (!draft.hook?.trim() || !draft.rationale?.trim()) {
    throw new Error("model returned a draft with no hook or no rationale");
  }

  return draft;
}

// ------------------------------------------------------------------ planning

async function planFor(db: SupabaseClient, userId: string): Promise<Record<string, unknown>> {
  const { data: settings } = await db
    .from("autopilot_settings")
    .select("*")
    .eq("user_id", userId)
    .maybeSingle<Settings>();

  if (!settings) return { userId, planned: 0, reason: "no settings row" };
  if (!settings.is_on) return { userId, planned: 0, reason: "autopilot is off" };

  // An account that cannot publish should not accumulate a queue. An unposted
  // backlog is worse than an empty one.
  const { data: accounts } = await db
    .from("social_accounts")
    .select("platform")
    .eq("user_id", userId)
    .is("disconnected_at", null);

  const connected = new Set((accounts ?? []).map((a) => a.platform as string));
  const platforms = settings.platforms.filter((p) => connected.has(p));
  if (platforms.length === 0) {
    return { userId, planned: 0, reason: "no connected account for the chosen platforms" };
  }

  const { data: pillars } = await db
    .from("content_pillars")
    .select("*")
    .eq("user_id", userId)
    .returns<Pillar[]>();

  if (!pillars?.some((p) => p.is_enabled)) {
    return { userId, planned: 0, reason: "no enabled pillars" };
  }

  const { data: recent } = await db
    .from("content_posts")
    .select("id, hook, pillar_id, status, scheduled_for, created_at")
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .limit(40)
    .returns<Post[]>();

  const history = recent ?? [];

  // Only fill up to what the horizon asks for. The queue is a buffer, not a
  // backlog: planning a month ahead means writing about a month the planner
  // knows nothing about.
  const pending = history.filter((p) => !["posted", "failed"].includes(p.status));
  const target = settings.posts_per_day * HORIZON_DAYS;
  const needed = Math.max(0, target - pending.length);
  if (needed === 0) {
    return { userId, planned: 0, reason: `queue is full (${pending.length}/${target})` };
  }

  const taken = new Set(
    pending
      .map((p) => (p.scheduled_for ? new Date(p.scheduled_for).getTime() : null))
      .filter((t): t is number => t !== null)
  );

  const created: string[] = [];
  const failures: string[] = [];
  const working = [...history];

  // One at a time, so each draft sees the ones before it and does not repeat
  // them. Slower than a batch, but a queue of three near-identical posts is
  // the failure people actually notice.
  for (let i = 0; i < needed; i++) {
    const pillar = choosePillar(pillars, working);
    if (!pillar) break;

    const platform = platforms[i % platforms.length];
    const slot = nextSlot(settings, new Date(), taken);
    if (!slot) {
      failures.push("no free slot inside the horizon");
      break;
    }

    try {
      const draft = await write(pillar, settings, platform, working);

      const { data: inserted, error } = await db
        .from("content_posts")
        .insert({
          user_id: userId,
          pillar_id: pillar.id,
          hook: draft.hook.trim(),
          script: draft.script.trim(),
          caption: draft.caption?.trim() ?? "",
          hashtags: (draft.hashtags ?? []).slice(0, 5),
          platform,
          // Written but not cleared to go. `requires_approval` decides whether
          // a person or the publisher moves it on from here.
          status: "scripted",
          rationale: draft.rationale.trim(),
          scheduled_for: slot.toISOString(),
          // Autopilot running unattended approves its own work. With approval
          // on, this stays null and the app shows it as awaiting review.
          approved_at: settings.requires_approval ? null : new Date().toISOString(),
        })
        .select("id, hook, pillar_id, status, scheduled_for, created_at")
        .single<Post>();

      if (error) throw new Error(error.message);

      taken.add(slot.getTime());
      working.unshift(inserted);
      created.push(inserted.id);
    } catch (cause) {
      // One bad draft should not abandon the rest of the run.
      failures.push(cause instanceof Error ? cause.message : String(cause));
    }
  }

  return { userId, planned: created.length, created, failures };
}

// --------------------------------------------------------------------- entry

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  if (!OPENAI_KEY) {
    return json({ error: "OPENAI_API_KEY is not set on this project." }, 500);
  }

  const authorization = req.headers.get("Authorization") ?? "";
  const body = await req.json().catch(() => ({}));

  // Service-role sweep: every autopilot that is on, for a cron to call.
  if (body?.sweep === true) {
    if (!authorization.includes(SERVICE_ROLE_KEY)) {
      return json({ error: "sweep requires the service role key" }, 403);
    }
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: active } = await admin
      .from("autopilot_settings")
      .select("user_id")
      .eq("is_on", true);

    const results = [];
    for (const row of active ?? []) {
      try {
        results.push(await planFor(admin, row.user_id as string));
      } catch (cause) {
        results.push({
          userId: row.user_id,
          planned: 0,
          reason: cause instanceof Error ? cause.message : String(cause),
        });
      }
    }
    return json({ swept: results.length, results });
  }

  // Single user. The client is built with the caller's own token, so every
  // read and write below is RLS-scoped to them -- there is no user id to pass
  // in and therefore none to forge.
  if (!authorization) return json({ error: "missing Authorization header" }, 401);

  const db = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY") ?? "", {
    global: { headers: { Authorization: authorization } },
  });

  const { data: auth, error: authError } = await db.auth.getUser();
  if (authError || !auth?.user) return json({ error: "not signed in" }, 401);

  try {
    return json(await planFor(db, auth.user.id));
  } catch (cause) {
    return json({ error: cause instanceof Error ? cause.message : String(cause) }, 500);
  }
});
