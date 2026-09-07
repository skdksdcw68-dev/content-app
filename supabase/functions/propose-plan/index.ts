/**
 * A month of content, laid out and written, in one request.
 *
 * This is the thing the product is actually for. Chat writing three ideas you
 * copy by hand is a nicer notepad; a plan that knows what goes out on the 14th
 * at 12:00 and why is a different object, because a schedule can run without
 * you and a list of ideas cannot.
 *
 * Two halves, deliberately separated:
 *
 *   WHEN is arithmetic. allocate_slots() lays out the timestamps in the brand's
 *   own timezone, skips quiet hours, skips the past, refuses to double-book,
 *   and picks each slot's pillar by weighted shortfall. A model asked to do
 *   that produces plausible nonsense and charges for it.
 *
 *   WHAT is the model's job. It is handed the slots -- the date, the weekday,
 *   the theme -- and writes one post for each.
 *
 * Nothing here is scheduled. The plan lands as `proposed` and stays a document
 * until a person calls activate_plan(). Writing thirty rows is cheap; posting
 * one is not.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");

/** The planner has its own dial, separate from Chat.
 *
 *  They are not the same job. Chat writes three ideas somebody reads and
 *  discards; the plan writes thirty posts somebody schedules and publishes, and
 *  the failure mode is not "a bit bland" but "announced a feature that does not
 *  exist". Measured rather than assumed -- see the note in the commit. */
const MODEL = Deno.env.get("PLANNER_MODEL") ?? Deno.env.get("LLM_MODEL") ?? "gpt-4.1-nano";

/** Written ten at a time. One call for thirty posts runs long enough to risk
 *  truncation, and quality falls off badly toward the end of a long list. */
const BATCH = 10;

/** gpt-4.1-nano, in cents per thousand tokens. Recorded rather than enforced --
 *  knowing what a plan costs comes before charging anyone for one. */
const CENTS_PER_1K_IN = 0.01;
const CENTS_PER_1K_OUT = 0.04;

interface Body {
  brief?: string;
  days?: number;
  posts_per_day?: number;
  starts_on?: string;
}

interface Slot {
  slot_at: string;
  pillar_id: string | null;
  day_index: number;
  slot_index: number;
}

interface Written {
  n?: number;
  hook?: string;
  caption?: string;
  concept?: string;
  hashtags?: string[];
  rationale?: string;
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
    const brief = (body.brief ?? "").trim();
    const days = clamp(body.days ?? 30, 1, 60);
    const perDay = clamp(body.posts_per_day ?? 1, 1, 6);

    // Read under RLS, so a caller cannot plan into somebody else's brand.
    const { data: brand } = await asUser
      .from("brands")
      .select("id, name, niche, audience, timezone")
      .limit(1)
      .maybeSingle();

    if (!brand) throw new PublicError("Set up your brand first.", 400);

    const { data: pillars } = await asUser
      .from("content_pillars")
      .select("id, name, detail")
      .eq("brand_id", brand.id)
      .eq("is_enabled", true);

    // What the agent has been told and now applies without being asked again.
    // The schema has had this table since 0002 and nothing has ever read it,
    // which is half the reason plans came out generic.
    const { data: memoryRows } = await asUser
      .from("brand_memory")
      .select("fact")
      .eq("brand_id", brand.id)
      .order("created_at", { ascending: false })
      .limit(20);

    const memory = (memoryRows ?? [])
      .map((row: { fact: string }) => (row.fact ?? "").trim())
      .filter(Boolean);

    // Everything concrete the planner may say comes from one of these. Counted
    // here so the response can report it.
    const facts = [
      brand.niche,
      brand.audience,
      brief,
      ...memory,
    ].filter((value) => typeof value === "string" && value.trim().length > 0);

    const pillarName = new Map<string, string>(
      (pillars ?? []).map((p: { id: string; name: string }) => [p.id, p.name]),
    );

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // Today as the BRAND would write it, not as the server would. On a UTC
    // server at 23:30 a Melbourne brand is already on tomorrow, and starting
    // its plan "yesterday" silently throws the first day away as being past.
    const startsOn = body.starts_on ?? todayIn(brand.timezone);

    const { data: slots, error: slotError } = await admin.rpc("allocate_slots", {
      p_brand_id: brand.id,
      p_starts_on: startsOn,
      p_days: days,
      p_posts_per_day: perDay,
    });

    if (slotError) {
      // The one failure worth naming: quiet hours covering every candidate hour
      // is a setting a person chose, and "no slots" would read as a bug.
      if (slotError.code === "23514" || /quiet hours/.test(slotError.message ?? "")) {
        throw new PublicError(
          "Your quiet hours cover the whole day, so there is nowhere to post. Widen them in settings.",
          409,
        );
      }
      throw slotError;
    }

    const laidOut = (slots ?? []) as Slot[];
    if (laidOut.length === 0) {
      throw new PublicError("Every slot in that range is already taken or in the past.", 409);
    }

    // What it has written before, so a second plan does not repeat the first.
    const { data: recent } = await asUser
      .from("posts")
      .select("hook")
      .order("created_at", { ascending: false })
      .limit(30);

    const used = new Set<string>(
      (recent ?? []).map((r: { hook: string }) => (r.hook ?? "").toLowerCase()).filter(Boolean),
    );

    const written: Written[] = [];
    let tokensIn = 0;
    let tokensOut = 0;

    for (let start = 0; start < laidOut.length; start += BATCH) {
      const result = await writeBatch({
        brand,
        brief,
        memory,
        pillars: pillars ?? [],
        pillarName,
        slots: laidOut.slice(start, start + BATCH),
        offset: start,
        avoid: [...used].slice(0, 40),
      });

      tokensIn += result.tokensIn;
      tokensOut += result.tokensOut;

      for (const post of result.posts) {
        if (post.hook) used.add(post.hook.toLowerCase());
      }
      written.push(...result.posts);
    }

    const byIndex = new Map<number, Written>();
    for (const post of written) {
      if (typeof post.n === "number") byIndex.set(post.n, post);
    }

    const { data: plan, error: planError } = await admin
      .from("content_plans")
      .insert({
        user_id: auth.user.id,
        brand_id: brand.id,
        title: brief ? brief.slice(0, 80) : `${days} days for ${brand.name}`,
        status: "proposed",
        starts_on: startsOn,
        days,
        posts_per_day: perDay,
        brief,
      })
      .select("id, title, starts_on, days, posts_per_day")
      .single();

    if (planError) throw planError;

    // A post without a rationale is dropped rather than given an invented one.
    // The line saying why this exists is the part a person reads before handing
    // over a publish key, and "the model said so" is not that line.
    const rows = [];
    let dropped = 0;
    let invented = 0;

    // Whether a fabricated person can be told apart from a real one at all. If
    // the account has actually collected things people said, "one reader wrote
    // in" may be legitimate and the filter below would throw away a good post.
    //
    // Narrow on purpose. The first version matched the bare word "people",
    // which appears in perfectly ordinary facts -- "the most common reason
    // people quit journalling is a blank page" -- and silently switched the
    // whole filter off. What is being asked here is not "does this mention
    // people" but "has this account got quotes from them".
    const factsMentionPeople =
      /\b(told (me|us)|wrote in|reviews?|testimonials?|feedback from|(users?|readers?|customers?)\s+(said|say|told|wrote))\b/i
        .test(facts.join(" "));

    // The same gate for claims about recent work. Somebody who wrote down what
    // they shipped this week should get a post about it; somebody who wrote
    // nothing should not have one invented for them.
    const factsMentionRecentWork =
      /\b(this week|this month|today|yesterday|recently|just (shipped|launched|added|released)|shipped|launched|released|added|rebuilt|redesigned)\b/i
        .test(facts.join(" "));

    for (const [i, slot] of laidOut.entries()) {
      const post = byIndex.get(i + 1);
      const hook = (post?.hook ?? "").trim();
      const rationale = (post?.rationale ?? "").trim();

      if (!hook || !rationale) {
        dropped += 1;
        continue;
      }

      // The one invention the prompt does not reliably prevent, and the one
      // that does most damage. "Reader stories: what people wrote in" is a
      // theme people will genuinely write, and it asks for a testimonial the
      // model does not have -- so it makes one up, on both nano and mini,
      // despite being forbidden twice.
      //
      // A fabricated feature is embarrassing. A fabricated customer is a
      // different category: it is a made-up person saying a made-up thing about
      // a real product, and it is the kind of post that gets an account in
      // trouble rather than merely ignored. Dropped rather than published, and
      // counted separately so the app can say why the month is short.
      const written = `${hook} ${post?.caption ?? ""}`;

      if (
        (!factsMentionPeople && inventsAPerson(written)) ||
        (!factsMentionRecentWork && claimsRecentWork(written))
      ) {
        dropped += 1;
        invented += 1;
        continue;
      }

      rows.push({
        user_id: auth.user.id,
        brand_id: brand.id,
        plan_id: plan.id,
        pillar_id: slot.pillar_id,
        day_index: slot.day_index,
        slot_index: slot.slot_index,
        format: "video",
        hook: hook.slice(0, 200),
        script: (post?.caption ?? "").trim(),
        concept: (post?.concept ?? "").trim(),
        rationale: rationale.slice(0, 300),
        status: "planned",
        // The first three days get made up front so the preview shows something
        // real; the rest wait until T-26h, because provider outputs expire in
        // about a week and day 30 would rot before it was ever published.
        render_tier: slot.day_index < 3 ? "eager" : "deferred",
        media_strategy: "generate",
        scheduled_for: slot.slot_at,
      });
    }

    if (rows.length === 0) {
      // Leave nothing half-made behind.
      await admin.from("content_plans").delete().eq("id", plan.id);
      throw new PublicError("Nothing usable came back from the writer. Try again.", 502);
    }

    const { error: postsError } = await admin.from("posts").insert(rows);
    if (postsError) throw postsError;

    const costCents = Math.round(
      (tokensIn / 1000) * CENTS_PER_1K_IN + (tokensOut / 1000) * CENTS_PER_1K_OUT,
    );

    await admin.from("usage_events").insert({
      user_id: auth.user.id,
      brand_id: brand.id,
      kind: "plan_write",
      units: rows.length,
      cost_cents: costCents,
      ref_table: "content_plans",
      ref_id: plan.id,
    });

    return json({
      plan_id: plan.id,
      title: plan.title,
      starts_on: plan.starts_on,
      days: plan.days,
      posts_per_day: plan.posts_per_day,
      planned: rows.length,
      // Reported, not hidden. Twenty-eight days of a thirty-day plan is a fact
      // the person should see rather than discover by counting.
      dropped,
      // Of the dropped, how many were dropped for inventing a person. Reported
      // separately because it means something different: not "the writer had a
      // bad batch" but "a theme is asking for something you have not told it".
      invented,
      // The cause, where the two counts above are symptoms: themes asking for
      // material this account has never written down. Named so the person can
      // feed them or switch them off, rather than wondering why a month keeps
      // coming back short.
      unsupported_themes: unsupportedThemes(
        pillars ?? [],
        factsMentionPeople,
        factsMentionRecentWork,
      ),
      slots: laidOut.length,
      // How much it had to go on. Measured and returned because it is the
      // single biggest lever on whether the month is worth posting: with five
      // facts this writes "no badges, no streaks: here is the reason"; with
      // none it writes "here is what went into it this week", which says
      // nothing. The app asks for more when this is low.
      facts_used: facts.length,
      model: MODEL,
      tokens: tokensIn + tokensOut,
    });
  } catch (error) {
    return fail(error);
  }
});

// ------------------------------------------------------------------ writing

async function writeBatch(args: {
  brand: { name: string; niche: string; audience: string };
  brief: string;
  /** What the person has told it about themselves, one fact per row. */
  memory: string[];
  pillars: Array<{ id: string; name: string; detail: string }>;
  pillarName: Map<string, string>;
  slots: Slot[];
  offset: number;
  avoid: string[];
}): Promise<{ posts: Written[]; tokensIn: number; tokensOut: number }> {
  const { brand, brief, memory, pillars, pillarName, slots, offset, avoid } = args;

  const system = [
    "You plan short-form video content for one social account.",
    'Return JSON only, matching: {"posts":[{"n":number,"hook":string,"caption":string,"concept":string,"hashtags":[string],"rationale":string}]}.',
    "Write exactly one entry per numbered slot, and set n to that slot's number.",
    "hook: the first line said on camera. Under 80 characters.",
    "caption: what goes under the video. Under 150 characters.",
    "concept: what the video shows, in one sentence, as an instruction to whoever makes it. Describe the shot, not the feeling.",
    "hashtags: 2 to 4, lowercase, each starting with #.",
    "rationale: one sentence saying why this post exists on this day. Never predict performance.",
    "Every entry must differ from every other. Avoid hype words and the word easy.",

    // The instruction that replaced "prefer a specific number, a specific cost,
    // or a specific mistake". That one produced plans announcing features the
    // product does not have -- "this week I added mood tracking" -- because the
    // model had no facts and was told to be specific, so it made specifics up.
    // A person who posts that has announced something untrue about their own
    // product, which is worse than a bad post.
    //
    // Stated as a banned list rather than a principle, because a small model
    // follows "never write X" and reasons poorly about "only assert what you
    // know". The examples are the failures the first version actually produced.
    "FACTS: everything you may treat as true is listed under FACTS below. Nothing else is known.",
    "NEVER write that anything was changed, added, removed, fixed, improved, tweaked, refined, updated, simplified, launched or shipped. You do not know whether it was. Sentences like \"this week I added...\", \"I tweaked...\", \"I made ... better\" are forbidden even as a theme suggests them.",
    "NEVER invent a number, a price, a date, a rating, a milestone, or a person. NEVER write a customer quote, a testimonial, or \"one user told me\". You have never met a user of this account.",
    "If a theme asks for something you have no fact for, cover the same subject WITHOUT the claim: show how the thing already works, ask what the audience does today, name a mistake common in this field, argue for a belief, or compare two approaches.",
    "Hooks: no two may begin with the same three words, and none may repeat an opening in the avoid list. Vary the grammatical form -- some questions, some statements, some instructions, some observations.",
  ].join("\n");

  // Everything under FACTS is something a person wrote down. Nothing else is
  // available to the model, and the system prompt says so -- which is what
  // stops a plan announcing features the product does not have.
  const facts = [
    `The account is called ${brand.name}.`,
    brand.niche ? `It is about: ${brand.niche}` : null,
    brand.audience ? `Its audience: ${brand.audience}` : null,
    brief ? `For these weeks specifically: ${brief}` : null,
    ...memory.map((fact) => fact),
  ].filter(Boolean);

  const about = [
    "FACTS:",
    ...facts.map((fact) => `- ${fact}`),
    facts.length <= 1
      ? "\nThat is everything known about this account. Write posts that do not depend on facts you were not given."
      : "",
    pillars.length > 0
      ? `\nThemes to rotate between:\n${pillars.map((p) => `- ${p.name}${p.detail ? `: ${p.detail}` : ""}`).join("\n")}`
      : "",
  ].filter(Boolean).join("\n");

  // The weekday is given because it changes what belongs there. A Saturday post
  // is not a Tuesday post, and asking a model to derive the weekday from a
  // timestamp costs tokens to get wrong.
  const lines = slots.map((slot, i) => {
    const when = new Date(slot.slot_at);
    const day = when.toLocaleDateString("en-GB", {
      weekday: "long",
      day: "numeric",
      month: "short",
      timeZone: "UTC",
    });
    const pillar = slot.pillar_id ? pillarName.get(slot.pillar_id) : null;
    return `${offset + i + 1}. ${day}${pillar ? ` - theme: ${pillar}` : ""}`;
  }).join("\n");

  const avoidBlock = avoid.length > 0
    ? `\nAlready used, do not repeat or paraphrase:\n${avoid.map((h) => `- ${h}`).join("\n")}`
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
        { role: "user", content: `${about}${avoidBlock}\n\nSlots:\n${lines}` },
      ],
    }),
  });

  const completion = await response.json();

  if (!response.ok) {
    console.error("openai", completion?.error);
    throw new PublicError("The writer could not be reached just now.", 502);
  }

  let posts: Written[] = [];
  try {
    const parsed = JSON.parse(completion.choices?.[0]?.message?.content ?? "{}");
    posts = Array.isArray(parsed.posts) ? parsed.posts : [];
  } catch {
    // One bad batch loses ten days, not the plan. The caller counts what came
    // back and reports the shortfall rather than failing the whole request.
    console.error("unparseable batch at offset", offset);
    posts = [];
  }

  return {
    posts,
    tokensIn: completion.usage?.prompt_tokens ?? 0,
    tokensOut: completion.usage?.completion_tokens ?? 0,
  };
}

// ------------------------------------------------------------------- utils

/**
 * Does this text claim a person the account has never mentioned?
 *
 * Deliberately narrow. It catches the family the prompt cannot hold -- a
 * testimonial, a quoted stranger, "one user told me" -- and nothing else. A
 * broader filter would have to decide whether "I built this alone" is true,
 * which is a question about the world and not about the string.
 *
 * Skipped entirely when the facts already talk about users, since then such a
 * post may be perfectly legitimate and dropping it would lose a good one.
 */
function inventsAPerson(text: string): boolean {
  const patterns = [
    // "one user said", "a reader wrote", "another customer found"
    /\b(one|a|another|our|some)\s+(user|users|reader|readers|customer|customers|follower|followers|person|people)\s+(said|says|told|wrote|shared|found|discovered|reported|mentioned)\b/i,
    // a correspondent who has to exist for the sentence to be true
    /\b(told|wrote to|wrote in to|messaged|emailed)\s+(me|us)\b/i,
    // a long quoted passage, which in a 150-character caption is a testimonial
    /["“][^"”]{25,}["”]/,
    /\bwhat\s+(people|users|readers|customers|someone)\s+(are\s+)?(saying|said|wrote|thinks?|thought)\b/i,
    // "here is what someone wrote", "what one person said on their first day"
    /\b(someone|somebody|a user|one user|a reader)\s+\w{0,12}?\s*(wrote|said|told|shared|posted)\b/i,
    // "real users share", "our users tell us"
    /\b(real|actual|our)\s+(users?|readers?|customers?)\s+\w{0,10}?\s*(share|shares|shared|say|says|said|tell|told)\b/i,
    // "thoughts from a Remi user", "a note by one reader"
    /\b(from|by)\s+(a|an|one|our|another)\s+\w{0,12}?\s*(user|reader|customer|follower)\b/i,
  ];
  return patterns.some((pattern) => pattern.test(text));
}

/**
 * Does this claim work done in a named recent period?
 *
 * "This week, I focused on making questions clearer" is the other leak the
 * prompt does not hold. It is not always wrong -- somebody who told the app
 * what they shipped this week should absolutely get a post about it -- so this
 * is gated the same way as the person filter: allowed when the facts talk about
 * recent work, refused when they do not.
 */
function claimsRecentWork(text: string): boolean {
  return /\b(this week|this month|today|yesterday|lately|recently|just)\b[^.!?]{0,40}\b(i|we)\s+(added|removed|built|shipped|launched|fixed|changed|updated|improved|tweaked|refined|simplified|streamlined|focused|worked|rebuilt|redesigned)\b/i
    .test(text);
}

/**
 * Which themes are asking for something this account has never written down.
 *
 * This is the cause, and the filters above are the symptom. A theme called
 * "Reader stories: what people wrote in" is a promise the account cannot keep
 * with no quotes on file, and no prompt fixes a theme that inherently requires
 * facts nobody has given. Asked to write to it, a model invents -- correctly,
 * in the sense that it is doing what it was told.
 *
 * Reported rather than refused. It is the person's account and their theme, and
 * the useful move is telling them which one is producing fiction so they can
 * either feed it or switch it off.
 */
function unsupportedThemes(
  pillars: Array<{ name: string; detail: string }>,
  hasPeopleFacts: boolean,
  hasRecentWorkFacts: boolean,
): string[] {
  const wantsPeople = /\b(stories|testimonial|review|feedback|community|what (people|users|readers|customers)|q ?& ?a|questions from)\b/i;
  const wantsWork = /\b(behind the (build|scenes)|changelog|what (i|we) (changed|shipped|built)|progress|updates?|build in public|devlog)\b/i;

  return pillars
    .filter((pillar) => {
      const text = `${pillar.name} ${pillar.detail}`;
      if (wantsPeople.test(text) && !hasPeopleFacts) return true;
      if (wantsWork.test(text) && !hasRecentWorkFacts) return true;
      return false;
    })
    .map((pillar) => pillar.name);
}

function clamp(value: number, low: number, high: number): number {
  return Math.min(Math.max(Math.round(value), low), high);
}

/** Today's date in a given zone, as YYYY-MM-DD. */
function todayIn(timezone: string): string {
  try {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(new Date());
  } catch {
    return new Date().toISOString().slice(0, 10);
  }
}
