/**
 * Deciding what the person actually wants, before spending anything on it.
 *
 * The rule this enforces:
 *
 *   UNDERSTAND -> CLARIFY -> CONFIRM -> REASON -> PRODUCE
 *
 * rather than the version that costs money: someone types a sentence, a large
 * model writes thirty days of content, and only then does anybody discover the
 * goal was wrong.
 *
 * Two things make that affordable rather than annoying.
 *
 * **The router is a cheap model.** Classifying "plan me a month" as a planning
 * request is not work worth a reasoning model, and putting one here would mean
 * paying strategy prices to answer "hi". Tiering is not an optimisation to do
 * later; it is the difference between a product and a bill.
 *
 * **What is already known is read from the database, not asked.** The agent
 * asks about the two things missing rather than the eleven it could ask about.
 * A question you already answered is the fastest way to make something feel
 * stupid, and each one is a round trip somebody has to sit through.
 */

/** What tier a piece of work deserves. The names are roles, not model ids, so
 *  the mapping moves without touching a call site. */
export const MODELS = {
  /** Intent, classification, small edits, metadata. Answers in under a second
   *  and costs almost nothing. */
  fast: Deno.env.get("FAST_MODEL") ?? "gpt-4.1-nano",
  /** Conversation, captions, revisions. The default for anything a person
   *  reads as prose. */
  chat: Deno.env.get("CHAT_MODEL") ?? "gpt-4.1-mini",
  /** Strategy, research synthesis, a month of planning, major changes. Used
   *  where the decision is actually worth the tokens and nowhere else. */
  deep: Deno.env.get("DEEP_MODEL") ?? "gpt-4.1",
} as const;

export type Intent =
  | "chat"        // talk to me
  | "plan"        // build or rebuild a stretch of content
  | "revise"      // change something that already exists
  | "make"        // produce one specific thing now
  | "research"    // find out about something, properly, in the background
  | "export"      // give me that as a file
  | "explain"     // what do you know, what did you do, why
  | "insights";   // how is my content doing, why, what should I post next

const INTENTS: Intent[] = ["chat", "plan", "revise", "make", "research", "export", "explain", "insights"];

export interface Routed {
  intent: Intent;
  /** How many days of content, when the request implies a stretch. */
  days: number | null;
  /** The router's one-line reading of the request, for the trail. */
  reading: string;
  /** For `make`: what kind of thing. Null when the request does not say, and
   *  then it is video, because that is what this product posts. */
  media: "image" | "video" | "audio" | null;
  /** For `export`: which file. Null when not named. */
  format: "docx" | "pdf" | "zip" | null;
  /** For `make`: WHAT to make, as a generation prompt -- the scene or the
   *  thing, never instructions to us, never model names or settings. The
   *  first real image was asked for as "I want a photo or image not a video",
   *  and that sentence is what went to the model. */
  subject: string | null;
  /** A generation model the person named, as they wrote it. */
  model: string | null;
  /** Settings the person asked for, in their own units. `count` is how many
   *  separate pictures they want, when it is more than one. */
  settings: { resolution?: string; aspect_ratio?: string; duration?: number; count?: number; quality?: string };
  /** They are asking about credits, balance, cost, topping up or their plan --
   *  the one time the account is worth checking before answering. */
  aboutCredits: boolean;
  /** For `make`: one entry for each separate thing asked for, each with its own
   *  instructions. "Five images, the first square and the second wide" is five
   *  entries, not a count and one set of settings. Abel, 1 Nov 2026: "nothing
   *  should be hard-coded or limited ... for the first image use this size,
   *  for the second image use this size." `subject`, `model`, `media` and
   *  `settings` above are the first entry's, for what reads only those. */
  jobs: RoutedJob[];
  /** How much the reply deserves. "full" for questions about their account,
   *  numbers or results and anything that asks why, how, or to analyze,
   *  compare, explain, advise or plan; "short" for small talk. Abel, 2 Nov
   *  2026: it is an analytics analyzer and "answers in two or three lines". */
  depth: "short" | "full";
  /** A question to put to them instead of guessing, when the request cannot
   *  go on without a guess they would care about. Null otherwise. */
  ask: string | null;
  /** Pictures from the conversation they want to SEE again ("send me the photo
   *  you made"), by handle. Nothing is made; the picture is shown. */
  show: string[];
}

/** One thing to make, as the person described it. */
export interface RoutedJob {
  media: "image" | "video" | "audio" | null;
  /** What THIS one is of, as a generation prompt -- style words included. */
  subject: string | null;
  model: string | null;
  /** Pictures from the conversation it starts from or must follow, by the
   *  handle the router was shown (P1, P2 ...). */
  uses: string[];
  settings: { resolution?: string; aspect_ratio?: string; duration?: number; quality?: string };
}

/** The most one request may ask for. Not a product limit: a model that loops
 *  must not be able to start a hundred paid jobs from one sentence. */
export const MAX_JOBS = 24;

/** One thing to ask, with the taps that answer it. */
export interface Question {
  key: "goal" | "appetite" | "audience" | "cadence";
  prompt: string;
  options: { value: string; label: string }[];
  /** Every question takes a typed answer as well. Buttons are a shortcut, not
   *  a cage -- somebody whose goal is not on the list should not have to pick
   *  the nearest wrong one. */
  allowsFreeText: boolean;
}

/** What the database says is already known about a brand. */
export interface Knowledge {
  has_niche: boolean;
  has_audience: boolean;
  fact_count: number;
  pillar_count: number;
  published_count: number;
  has_metrics: boolean;
  has_generator: boolean;
  has_connection: boolean;
  posts_per_day: number | null;
  strategy_id: string | null;
  strategy_approved: boolean;
}

const QUESTIONS: Record<string, Question> = {
  goal: {
    key: "goal",
    prompt: "What is this month for?",
    options: [
      { value: "followers", label: "Grow followers" },
      { value: "customers", label: "Get customers" },
      { value: "awareness", label: "Build awareness" },
      { value: "launch", label: "Promote a launch" },
    ],
    allowsFreeText: true,
  },
  appetite: {
    key: "appetite",
    prompt: "How much should it risk?",
    options: [
      { value: "conservative", label: "Play it safe" },
      { value: "balanced", label: "Balanced" },
      { value: "aggressive", label: "Push hard" },
    ],
    allowsFreeText: true,
  },
  audience: {
    key: "audience",
    prompt: "Who is this for?",
    options: [],
    allowsFreeText: true,
  },
  cadence: {
    key: "cadence",
    prompt: "How often should it post?",
    options: [
      { value: "1", label: "Once a day" },
      { value: "2", label: "Twice a day" },
      { value: "3", label: "Three a day" },
    ],
    allowsFreeText: true,
  },
};

/**
 * What still has to be asked before a plan can be built.
 *
 * Ordered by how much the answer changes the output, and capped at three.
 * Everything past the third is something the agent can decide well enough on
 * its own, and a form is not a conversation -- the point of asking at all is
 * that two taps beat a wasted month, not that more questions are better.
 */
export function missingForPlan(known: Knowledge, strategy: Record<string, unknown> | null): Question[] {
  const asked: Question[] = [];
  const has = (field: string) => {
    const value = strategy?.[field];
    return value !== null && value !== undefined && value !== "";
  };

  if (!has("goal")) asked.push(QUESTIONS.goal);
  // Only when the brand itself does not say. Asking somebody to retype what
  // they entered during setup is the exact behaviour this file exists to stop.
  if (!known.has_audience && !has("audience")) asked.push(QUESTIONS.audience);
  if (!has("appetite")) asked.push(QUESTIONS.appetite);
  // Cadence has a real default and a settings screen that owns it, so it is
  // asked last and usually not at all.
  if (known.posts_per_day === null && !has("cadence")) asked.push(QUESTIONS.cadence);

  return asked.slice(0, 3);
}

/**
 * Reads the request. One cheap call, JSON out, and a safe answer if anything
 * about it goes wrong.
 *
 * Falling back to "chat" on failure is deliberate: the failure mode of a
 * misread is a conversation instead of a month of content, which is the cheap
 * direction to be wrong in.
 */
export async function route(
  message: string,
  apiKey: string,
  context = "",
  /** Told what the call cost, so it can be recorded and taken from the
   *  person's meter. It runs on every message and was never counted. */
  onUsage?: (model: string, usage: { prompt_tokens?: number; completion_tokens?: number } | null) => Promise<void>,
  /** The pictures in this conversation, one per line, each led by the handle
   *  the router answers with (P1, P2 ...). */
  pictures = "",
  /** Which tier reads it. A request for several different things is worth the
   *  better one; "hi" is not. */
  tier: "chat" | "deep" = "chat",
): Promise<Routed> {
  const system = [
    "Classify the LAST message from someone running a social media account. JSON only.",
    '{"intent":"chat|plan|revise|make|research|export|explain|insights","days":number|null,' +
    '"media":"image|video|audio"|null,"format":"docx|pdf|zip"|null,"reading":string,' +
    '"about_credits":boolean,"depth":"short|full","ask":string|null,"show":[string],' +
    '"jobs":[{"media":"image|video|audio"|null,"subject":string|null,"model":string|null,"uses":[string],' +
    '"settings":{"resolution":string|null,"aspect_ratio":string|null,"duration":number|null,"quality":string|null}}]}',
    "",
    "You also get the recent conversation. USE IT. 'try again', 'that', 'make it a photo instead',",
    "'not a video', or just a model name all continue what was being made before -- they are make,",
    "about the same subject, never a new plan or a chat.",
    "",
    "plan     — wants content planned across a stretch of days.",
    "revise   — wants something that already exists changed.",
    "make     — wants an image or a video generated now.",
    "research — they ask you to research, investigate or dig into something OUTSIDE themselves: a market,",
    "  competitors, an industry, a trend, a technology. NEVER a question about their own content, account,",
    "  audience or what they should do: 'what kind of content should I make', 'what should I post', 'how do I",
    "  grow', 'give me ideas' are advice -- chat, depth full -- or plan when they want it built.",
    "export   — wants something from this conversation as a file: a document, a PDF, a zip.",
    "explain  — asking what you know, what you did, or why.",
    "insights — asking how THEIR posts or account are performing: views, likes, followers, why a post did",
    "  well or badly, why views are dropping, what changed this month, their top patterns, the best time",
    "  to post, which posts to make variations of, what to post next based on results, whether Autopilot",
    "  is working. Wanting a plan actually BUILT is plan, even when it says 'using what worked'.",
    "  'my last post', 'my latest video', 'how is my tiktok doing', 'check the one called ...',",
    "  'how many views did it get', 'which video did best' are all insights.",
    "chat     — anything else, including greetings, questions about you, and writing captions or hooks.",
    "",
    "days: only when a stretch is implied. 'a month' is 30, 'next week' is 7.",
    "media: for make only. 'image' for a picture, photo, thumbnail, poster; 'video' for a clip, reel, video;",
    "  'audio' for music, a song, a beat, a soundtrack, a sound effect, a voiceover or narration.",
    "  if they named an image model (Nano Banana, Soul, GPT Image, Seedream, Flux...) it is image. null if unsaid.",
    "format: for export only. 'docx' for Word or a document, 'pdf' for PDF, 'zip' for everything or a package.",
    "reading: one short sentence, in your own words, of what they are asking for.",
    "jobs: for make only, otherwise []. ONE entry for each separate thing to make. 'five images' is five",
    "  entries; 'a picture and a video of it' is two. Each entry carries ITS OWN instructions, so",
    "  'the first one square, the second wide' puts aspect_ratio '1:1' on the first and '16:9' on the second,",
    "  and 'make the third one in watercolour' puts that style in the third one's subject. An instruction",
    "  meant for all of them is repeated on every entry. Never put how many into a subject: each entry is",
    "  ONE thing, and 'four images' as a prompt comes back as one picture split into four.",
    "  media: 'image' for a picture, photo, thumbnail, poster; 'video' for a clip, reel, video; 'audio' for",
    "    music, a beat, a voiceover. A model they named (Nano Banana, Soul, GPT Image, Seedream, Flux) is an",
    "    image. null if unsaid.",
    "  subject: WHAT this one is, as a short generation prompt in plain words -- the scene or the thing, with",
    "    any style they asked for. Never instructions to you, never model names, never settings. Take it from",
    "    earlier in the conversation when the last message only changes how. null when they have not said",
    "    what yet -- a bare kind ('an image', 'a video', 'a picture') is NOT a subject. Examples:",
    "    'No i said generate an image of tea with a cup' -> one entry, subject 'a cup of tea'.",
    "    'Use nano banana pro with 2k' after asking for a cup of tea -> one entry, subject 'a cup of tea'.",
    "    'I want a photo not a video' after asking for a cup of tea -> one entry, media 'image', 'a cup of tea'.",
    "    'Lets generate an image bro' with nothing earlier -> one entry, subject null.",
    "    '4 different outfits like this' with a photo -> four entries, each a different outfit flat-lay in the",
    "    same style as the example.",
    "    'make 3 of these' -> three entries with the same subject.",
    "    Animating a picture: subject is what should HAPPEN in it -- the motion -- or null when they did not",
    "    say. Never a phrase pointing back at the picture. 'animate this photo' -> null.",
    "  model: a generation model they named for THIS entry, exactly as written ('nano banana pro2', 'soul 2',",
    "    'kling'), else null. A model named for everything goes on every entry.",
    "  uses: the pictures this entry starts from or must follow, by the handles in 'Pictures in this",
    "    conversation' (P1, P2 ...). 'edit the second one' -> ['P2']; 'use the photo I sent' -> its handle; a",
    "    video from pictures ('turn them into a video', 'make a video from these') is media 'video' and uses =",
    "    those pictures, the first being the start and the last the end. [] when it starts from nothing.",
    "    Only handles that are in the list.",
    "  settings: only what they asked for THIS entry. resolution like '1k','2k','4k','720p','1080p';",
    "    aspect_ratio like '9:16','16:9','1:1','4:5','3:4'; duration in seconds; quality 'low','medium' or",
    "    'high'. null for anything not asked.",
    "    The PLACE a thing is for sets its shape even when no ratio is said: a YouTube thumbnail or a YouTube",
    "    video is '16:9'; a TikTok, Reel, Short or Story is '9:16'; an Instagram feed post is '4:5'; a profile",
    "    picture or logo is '1:1'. Do not leave aspect_ratio null for these, and do not repeat an earlier shape",
    "    that was for somewhere else.",
    "show: handles (P1, P2 ...) of pictures YOU made that they ask to be SENT or SHOWN again -- 'send me the",
    "  photo you generated', 'show me that picture again'. Nothing is made: it is chat. [] otherwise.",
    "about_credits: true when they ask about credits, balance, top up, cost, price or their plan",
    "  ('do I have to top up?', 'how many credits do I have', 'why did it fail, is it money'). Such a",
    "  question is chat, not make.",
    "depth: how much the reply deserves. 'full' when they ask about their account, posts, numbers or results, why",
    "  something happened, or want you to analyze, compare, explain, advise or plan -- anything where the reasoning",
    "  is the value. 'short' for greetings, thanks, one-word answers and small talk, and for make.",
    "ask: one short question, or null. Ask ONLY when you cannot go on without a guess they would care about: which",
    "  picture they mean when several fit, what a video or a set should be of when nothing earlier says, two",
    "  instructions that contradict each other, something that would cost real money to get wrong. Name the",
    "  likely options in the question. When a sensible reading exists, do not ask: take it and put what you",
    "  assumed in 'reading'. Never ask what the conversation or their settings already answer.",
  ].join("\n");

  try {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        // The chat tier, not the fast one, since the router started reading
        // the conversation. "Try again please" was classified as a planning
        // request by the cheap model reading one line in isolation -- and a
        // misread here costs a round trip or, worse, the wrong paid job.
        model: tier === "deep" ? MODELS.deep : MODELS.chat,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: system },
          ...(context ? [{ role: "user", content: `Recent conversation:\n${context}` }] : []),
          ...(pictures ? [{ role: "user", content: `Pictures in this conversation, oldest first:\n${pictures}` }] : []),
          { role: "user", content: `Last message: ${message}` },
        ],
      }),
    });

    if (!response.ok) return fallback(message);

    const body = await response.json();
    await onUsage?.(body.model ?? MODELS.chat, body.usage ?? null).catch(() => {});
    const parsed = JSON.parse(body.choices?.[0]?.message?.content ?? "{}");
    const intent = parsed?.intent;
    const text = (value: unknown) => typeof value === "string" && value.trim() ? value.trim() : null;
    const jobs = readJobs(parsed);
    const first = jobs[0];

    return {
      intent: INTENTS.includes(intent) ? intent : "chat",
      days: typeof parsed?.days === "number" && parsed.days > 0
        ? Math.min(Math.round(parsed.days), 30)
        : null,
      reading: typeof parsed?.reading === "string" ? parsed.reading : message.slice(0, 80),
      media: ["image", "video", "audio"].includes(parsed?.media) ? parsed.media : first?.media ?? null,
      format: ["docx", "pdf", "zip"].includes(parsed?.format) ? parsed.format : null,
      subject: first?.subject ?? null,
      model: first?.model ?? null,
      // What reads only one set of settings gets the first entry's, with how
      // many as the count -- a set of the same thing is still one request.
      settings: {
        ...(first?.settings ?? {}),
        ...(jobs.length > 1 ? { count: jobs.length } : {}),
      },
      aboutCredits: parsed?.about_credits === true,
      jobs,
      depth: parsed?.depth === "full" || ["insights", "explain", "research"].includes(intent) ? "full" : "short",
      ask: text(parsed?.ask)?.slice(0, 300) ?? null,
      show: Array.isArray(parsed?.show)
        ? parsed.show.map(String).filter((handle: string) => /^P\d{1,3}$/.test(handle)).slice(0, 8)
        : [],
    };
  } catch {
    return fallback(message);
  }
}

/**
 * The entries of "jobs", read defensively: the model is asked for a shape and
 * gives roughly it. An old-style answer (one subject, a count) still works.
 */
function readJobs(parsed: Record<string, unknown> | null | undefined): RoutedJob[] {
  const text = (value: unknown) => typeof value === "string" && value.trim() ? value.trim() : null;
  const settingsOf = (raw: unknown): RoutedJob["settings"] => {
    const s = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
    return {
      ...(text(s.resolution) ? { resolution: text(s.resolution)!.toLowerCase() } : {}),
      ...(text(s.aspect_ratio) ? { aspect_ratio: text(s.aspect_ratio)! } : {}),
      ...(typeof s.duration === "number" && s.duration > 0 ? { duration: Math.round(s.duration) } : {}),
      ...(["low", "medium", "high"].includes(String(s.quality ?? "").toLowerCase())
        ? { quality: String(s.quality).toLowerCase() }
        : {}),
    };
  };
  const one = (raw: unknown): RoutedJob => {
    const e = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
    const subject = text(e.subject);
    return {
      media: ["image", "video", "audio"].includes(String(e.media)) ? e.media as RoutedJob["media"] : null,
      subject: subject && !vagueSubject(subject) ? subject.slice(0, 600) : null,
      model: text(e.model)?.slice(0, 60) ?? null,
      uses: Array.isArray(e.uses)
        ? e.uses.map(String).filter((handle) => /^P\d{1,3}$/.test(handle)).slice(0, 8)
        : [],
      settings: settingsOf(e.settings),
    };
  };

  const listed = Array.isArray(parsed?.jobs) ? parsed!.jobs as unknown[] : [];
  if (listed.length > 0) return listed.slice(0, MAX_JOBS).map(one);

  // The old shape: one subject, one model, one set of settings and a count.
  const legacy = one({ media: parsed?.media, subject: parsed?.subject, model: parsed?.model, settings: parsed?.settings });
  const many = Number((parsed?.settings as Record<string, unknown> | undefined)?.count);
  const asked = Number.isFinite(many) && many > 1 ? Math.min(MAX_JOBS, Math.round(many)) : 1;
  return legacy.subject || legacy.model || legacy.media || asked > 1
    ? Array.from({ length: asked }, () => ({ ...legacy }))
    : [];
}

/**
 * Words that name a KIND of thing, not a thing. "Lets generate an image bro"
 * came back with the subject "an image", which went to Nano Banana Pro as the
 * whole prompt -- and a rainy Paris street came back that nobody asked for.
 * Checked here as well as in the prompt, because the prompt is a request.
 */
const KIND_WORDS = new Set([
  "a", "an", "the", "some", "one", "any", "another", "new", "me", "my", "us", "for", "of", "to",
  "it", "this", "that", "please", "pls", "bro", "bruh", "man", "just", "quick", "short", "again",
  "cool", "nice", "good", "great", "random", "anything", "something", "stuff", "ai", "content",
  "image", "images", "picture", "pictures", "pic", "pics", "photo", "photos", "video", "videos",
  "clip", "clips", "reel", "reels", "visual", "visuals", "post", "thumbnail", "poster",
  "generate", "make", "create", "lets", "let", "s", "do", "can", "you", "i", "want", "need",
  // The router sometimes describes the asker instead of the thing: "the photo
  // they want to animate" is not a subject.
  "they", "them", "wants", "wanted", "asked", "asks", "user", "person", "here", "sent",
]);

export function vagueSubject(subject: string | null | undefined): boolean {
  if (!subject) return true;
  const words = subject.toLowerCase().replace(/[^a-z0-9\s]/g, " ").split(/\s+/).filter(Boolean);
  return words.every((word) => KIND_WORDS.has(word));
}

/** "surprise me", "you pick", "anything" -- what to make, left to Autocast. */
export function leftToUs(message: string): boolean {
  return /\b(surprise me|you (choose|pick|decide)|up to you|your (choice|call)|anything|whatever|random)\b/i
    .test(message);
}

function fallback(message: string): Routed {
  return {
    intent: "chat", days: null, reading: message.slice(0, 80), media: null, format: null,
    subject: null, model: null, settings: {}, aboutCredits: false, jobs: [], depth: "short", ask: null, show: [],
  };
}
