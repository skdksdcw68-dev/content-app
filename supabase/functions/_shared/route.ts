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
  /** A chat answer that searches the web first. Tested 3 Nov 2026 on "what games
   *  are available today" from Addis: gpt-4.1 was quick (5-7 s) but got kick-off
   *  times three hours out; gpt-4.1-mini, gpt-5.4-mini and gpt-5.5 at low effort
   *  were quicker still and said there were no games at all. gpt-5.5 at medium
   *  gave ChatGPT's own answer -- the Champions League night at 8:45 and 11 PM,
   *  the Championship games, a pick -- first words at about 15 s. */
  //  3 Nov 2026: gpt-5.6-terra at low searched and answered "what's trending" in
  //  about 11 s, better than gpt-5.5, at under half its price.
  web: Deno.env.get("WEB_MODEL") ?? "gpt-5.6-terra",
  /** The chat's everyday replies and the router's first read. Abel, 3 Nov
   *  2026: the chat felt "so dumb" on gpt-4.1-mini, a 2025 model that thought it
   *  was 2024. gpt-5.6-luna costs the same per message and is a 2026 model. */
  quick: Deno.env.get("QUICK_MODEL") ?? "gpt-5.6-luna",
  /** The chat's big questions (depth full), the router's second read for
   *  anything that makes something, and campaign strategy. */
  smart: Deno.env.get("SMART_MODEL") ?? "gpt-5.6-terra",
  /** Normal talk, 5 Nov 2026 (Abel): Claude Haiku 5.5, through OpenRouter. */
  talk: Deno.env.get("TALK_MODEL") ?? "anthropic/claude-haiku-5.5",
  /** Anything that needs a mind -- a full answer, the prompts for a picture or
   *  video -- Claude Sonnet 5.5 thinking. Web answers stay on `web` (OpenAI). */
  think: Deno.env.get("THINK_MODEL") ?? "anthropic/claude-sonnet-5.5",
  /** Only when picked in the chat's model picker, on Max and Ultra. */
  opus: Deno.env.get("OPUS_MODEL") ?? "anthropic/claude-opus-5.5",
} as const;

/** Set once Abel's OpenRouter credit is in: `talk` and `think` need it. Without
 *  it every call keeps going to OpenAI, as before. */
export const OPENROUTER_KEY = Deno.env.get("OPENROUTER_API_KEY") ?? "";

/** Where a chat-completions call for `model` goes. OpenRouter names its models
 *  "vendor/name"; OpenAI's have no slash. */
export function completionsFor(model: string, openaiKey: string): { url: string; key: string } {
  return model.includes("/")
    ? { url: "https://openrouter.ai/api/v1/chat/completions", key: OPENROUTER_KEY }
    : { url: "https://api.openai.com/v1/chat/completions", key: openaiKey };
}

/** How hard `think` reasons: low for the JSON prompts the router writes (speed),
 *  medium for a full answer. */
export const THINK_EFFORT = (Deno.env.get("THINK_EFFORT") ?? "medium") as "low" | "medium" | "high";

/** How hard the web model thinks before it writes; see `MODELS.web`. */
export const WEB_EFFORT = (Deno.env.get("WEB_EFFORT") ?? "low") as "none" | "low" | "medium";

/** How hard the chat's own replies think. "low" answered "yo bro" in about 2 s. */
export const REPLY_EFFORT = (Deno.env.get("REPLY_EFFORT") ?? "low") as "none" | "low" | "medium";

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
  /** They ask to HEAR or browse the voices on offer ("show me some voices").
   *  Nothing is made: a few samples are played back instead. */
  voices: boolean;
  /** The answer needs the live web -- today's games, news, prices, anything
   *  current or specific -- so the reply searches before it writes, in the
   *  chat, in seconds. Abel, 3 Nov 2026, with ChatGPT answering "what games
   *  are on today" in 9 s beside our five-minute report on Google Doodles. */
  web: boolean;
  /** They want what they asked for made and SENT to them at a set time, once
   *  or on repeat ("send them at 2 am", "every morning"). Abel, 3 Nov 2026:
   *  "it can produce whenever, but it must send it at the exact time." */
  schedule: RoutedSchedule | null;
  /** One honest sentence when they want it sooner than it can be made ("a
   *  video in the next 2 minutes"), else null. Abel, 4 Nov 2026: "the AI
   *  should be honest about everything." */
  timing: string | null;
  /** The read itself failed (every model refused): nothing is known about the message. */
  unavailable?: boolean;
}

/** When a scheduled request arrives, in the person's own local time. */
export interface RoutedSchedule {
  /** The first delivery, local: "2026-11-04T02:00". */
  at: string;
  /** More times for the same thing, local ("at 8:21 and again at 8:23"). Abel's
   *  4 Nov test asked for two; only the first was kept and the second went into
   *  the caption. */
  also: string[];
  repeat: "none" | "daily" | "weekdays" | "weekly" | "custom";
  /** 0 = Sunday ... 6 = Saturday, for weekly and custom. */
  days: number[];
  /** The words to send with it ("a caption for each"), or null. */
  text: string | null;
  /** A short name for it: "5 outfit pictures + captions". */
  label: string;
  /** They said exactly what and exactly when, so it is set without asking.
   *  False opens the Schedule sheet (Abel, 4 Nov 2026: the sheet is for when
   *  they have not fully explained). */
  settled: boolean;
}

/** One thing to make, as the person described it. */
export interface RoutedJob {
  media: "image" | "video" | "audio" | null;
  /** For audio: someone SPEAKING words (a voiceover, narration, "say this") as
   *  against music, a beat or a sound effect. Speech goes to a voice model. */
  speech: boolean;
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
    '"about_credits":boolean,"depth":"short|full","ask":string|null,"show":[string],"voices":boolean,"web":boolean,' +
    '"schedule":{"at":"YYYY-MM-DDTHH:MM","also":["YYYY-MM-DDTHH:MM"],"repeat":"none|daily|weekdays|weekly|custom","days":[number],"text":string|null,"label":string,"settled":boolean}|null,"timing":string|null,' +
    '"jobs":[{"media":"image|video|audio"|null,"speech":boolean,"subject":string|null,"model":string|null,"uses":[string],' +
    '"settings":{"resolution":string|null,"aspect_ratio":string|null,"duration":number|null,"quality":string|null}}]}',
    "",
    "You also get the recent conversation. USE IT. 'try again', 'that', 'make it a photo instead',",
    "'not a video', or just a model name all continue what was being made before -- they are make,",
    "about the same subject, never a new plan or a chat.",
    "",
    "This is Postpilot, a content creation app. Here 'content' means posts and videos for their social",
    "accounts, and 'what's trending', 'what's new today', 'what's hot' mean what is trending for creators",
    "right now on TikTok, Reels, Shorts and X -- sounds, formats, challenges, memes, topics -- not the news.",
    "People type fast or speak: read slang, typos and short forms for what they mean ('u' is you, 'uk' is",
    "often 'you know').",
    "",
    "plan     — wants content planned across a stretch of days: 'plan my month', 'a two-week campaign'.",
    "  'Handle everything', 'do it all for me', 'you do it' are NOT plan on their own: they continue",
    "  what the conversation was about, and you pick and do it -- usually chat, depth full.",
    "revise   — wants something that already exists changed.",
    "make     — wants an image, a video or a voice generated now. 'Let's make content', 'make a content",
    "  about it' with no picture, video or voice named is chat, depth full: the reply writes the actual",
    "  content -- the idea, the hook, the script, the caption -- and offers to make it.",
    "research — they ask for a REPORT or DEEP research: 'deep research ...', 'write me a report on ...', 'a full",
    "  breakdown I can export', 'research it thoroughly'. It runs for minutes and comes back as a document.",
    "  Anything that only needs looking up -- 'what games are on today', 'search for ...', 'check Google for ...',",
    "  'research the best ring lights' -- is chat with web true, answered in seconds the way ChatGPT does.",
    "  NEVER a question about their own content, account, audience or what they should do: 'what kind of",
    "  content should I make', 'what should I post', 'how do I grow', 'give me ideas' are advice -- chat,",
    "  depth full -- or plan when they want it built.",
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
    "  speech: true only when media is 'audio' and the sound is someone SPEAKING words -- 'generate a voice',",
    "    'voiceover', 'narrate this', 'say this', 'read it out', text to speech. false for music, songs, beats,",
    "    soundtracks and sound effects. For speech, the subject is the words to be spoken, exactly as given (or",
    "    null if they have not said what it should say).",
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
    "    'kling'), else one they said in words to use ALWAYS / FROM NOW ON / EVERY TIME for this kind (in the",
    "    conversation or in what Postpilot remembers), else null. A model they used, tapped or wanted once is NOT",
    "    that: leave it null so they are asked. A model named for everything goes on every entry.",
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
    "schedule: when they want what they ask for made and SENT TO THEM at a set time or on repeat ('send them at",
    "  2 am', 'every morning at 9', 'every Friday', 'daily'). intent is make and jobs are written as usual. at = the",
    "  FIRST delivery in THEIR local time, read from the 'Now, where they are' line (a time already past today",
    "  means tomorrow; 'in 5 minutes' is now plus 5). also = every OTHER time the same thing is sent ('at 8:21 and",
    "  again at 8:23' -> also ['...T08:23']), else []. repeat: none, daily, weekdays, weekly (days = that weekday) or",
    "  custom (days = the weekdays), days 0=Sunday..6=Saturday. text = the WORDS they asked to get with it ('a",
    "  caption for each', 'a hook and a caption'), else null -- never an instruction, a time or a note to yourself.",
    "  label = a short name for what arrives ('5 outfit pictures + captions'). settled = true only when they said",
    "  exactly what and exactly when -- a clock time or 'in N minutes', and the days for a repeat -- so nothing was",
    "  guessed; false when the time is vague ('tonight', 'later', 'every morning' with no hour, 'tomorrow') or you",
    "  filled something in. null when they want it now. Posting to their social accounts at a time is not this.",
    "timing: how long things take here: a picture about 40 seconds (up to 2 minutes), a voice a few seconds, an AI",
    "  video 2 to 5 minutes, a photo video 3 to 10 minutes. When they want something sooner than that ('a video in",
    "  the next 2 minutes', 'send it in 30 seconds'), one short honest sentence saying how long it really takes, in",
    "  their language; else null. The LENGTH of the video they want ('30 seconds', 'a minute') is not a deadline:",
    "  that is null here, always.",
    "show: handles (P1, P2 ...) of pictures YOU made that they ask to be SENT or SHOWN again -- 'send me the",
    "  photo you generated', 'show me that picture again'. Nothing is made: it is chat. [] otherwise.",
    "voices: true when they ask to hear, see, browse or choose between voices ('show me some voices', 'what",
    "  voices do you have', 'let me hear a few'). Nothing is made: it is chat, with jobs [].",
    "web: true when a good answer needs the internet -- facts you cannot know without looking: anything about",
    "  today, tonight, this week or now (games and matches, scores, news, weather, prices, releases, events,",
    "  what is trending), a specific product, place, company, person, app or website, or they say search,",
    "  google, look up, check online. Read casual words the way a person means them: 'what games are on",
    "  today' is the day's matches, not games to play. Advice or content BUILT ON what is happening now",
    "  ('make content from the trends', 'what should I post today') needs it too. false for small talk,",
    "  advice that does not depend on today, their own account (ACCOUNT has it), and for make.",
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
    "  assumed in 'reading'. Never ask what the conversation or their settings already answer. When they",
    "  hand the choice to you ('you pick', 'you decide', 'give me the details yourself', 'handle it'),",
    "  choose: null. Never ask again something Postpilot already asked in the conversation: take the most",
    "  likely answer instead.",
    "  HOW to ask, the way Claude does: one friendly, specific question in plain words, then 2 to 4 concrete",
    "  options in the same message (a short numbered list), and say which one you would pick if they do not",
    "  care. No lecture, no stack of questions, no 'could you clarify'.",
  ].join("\n");

  try {
    const read = (model: string) => {
      const to = completionsFor(model, apiKey);
      return fetch(to.url, {
        method: "POST",
        headers: { Authorization: `Bearer ${to.key}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          ...(model.includes("/") ? { reasoning: { effort: "low" } } : {}),
          // The chat tier, not the fast one, since the router started reading
          // the conversation. "Try again please" was classified as a planning
          // request by the cheap model reading one line in isolation -- and a
          // misread here costs a round trip or, worse, the wrong paid job.
          model,
          response_format: { type: "json_object" },
          messages: [
            { role: "system", content: system },
            ...(context ? [{ role: "user", content: `Recent conversation:\n${context}` }] : []),
            ...(pictures ? [{ role: "user", content: `Pictures in this conversation, oldest first:\n${pictures}` }] : []),
            { role: "user", content: `Last message: ${message}` },
          ],
        }),
      });
    };

    // The second read of a make or revise writes the prompts: Sonnet thinking
    // when OpenRouter is set up, the old model otherwise.
    // 9 Nov 2026: the OpenAI account ran out of credit, and every read failed
    // quietly into "chat": nothing Abel asked for was ever made. With OpenRouter
    // set up the first read is Claude Haiku too, and it falls back to Sonnet
    // before it ever falls back to OpenAI.
    let model: string = tier === "deep"
      ? (OPENROUTER_KEY ? MODELS.think : MODELS.smart)
      : (OPENROUTER_KEY ? MODELS.talk : MODELS.quick);
    let response = await read(model);
    if (!response.ok && OPENROUTER_KEY && model === MODELS.talk) {
      console.warn("route: haiku failed", response.status);
      model = MODELS.think;
      response = await read(model);
    }
    // Refused -- no credit for the newer models, as on 3 Nov 2026, when only
    // gpt-4.1-mini still answered: the old model rather than no reading at all.
    if (!response.ok && model !== MODELS.chat) {
      console.warn("route: falling back", model, response.status);
      model = model.includes("/") ? MODELS.smart : MODELS.chat;
      response = await read(model);
      if (!response.ok && model !== MODELS.chat) {
        model = MODELS.chat;
        response = await read(model);
      }
    }

    if (!response.ok) return fallback(message);

    const body = await response.json();
    await onUsage?.(body.model ?? model, body.usage ?? null).catch(() => {});
    // Claude sometimes wraps the object in a code fence.
    const said: string = body.choices?.[0]?.message?.content ?? "{}";
    const parsed = JSON.parse(said.slice(said.indexOf("{"), said.lastIndexOf("}") + 1) || "{}");
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
      voices: parsed?.voices === true,
      // Looking things up is part of a chat answer; a report searches on its
      // own, and making something never needs it.
      web: parsed?.web === true && intent === "chat",
      schedule: intent === "make" ? readSchedule(parsed?.schedule) : null,
      timing: intent === "make" ? text(parsed?.timing)?.slice(0, 240) ?? null : null,
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
      speech: e.speech === true && e.media === "audio",
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

/** "surprise me", "you pick", "anything" -- what to make, left to Postpilot. */
export function leftToUs(message: string): boolean {
  return /\b(surprise me|you (choose|pick|decide)|up to you|your (choice|call)|anything|whatever|random)\b/i
    .test(message);
}

function fallback(message: string): Routed {
  return {
    intent: "chat", days: null, reading: message.slice(0, 80), media: null, format: null,
    subject: null, model: null, settings: {}, aboutCredits: false, jobs: [], depth: "short", ask: null, show: [], voices: false,
    web: false, schedule: null, timing: null, unavailable: true,
  };
}

/** The schedule, read defensively; null unless it names a usable first time. */
function readSchedule(raw: unknown): RoutedSchedule | null {
  if (!raw || typeof raw !== "object") return null;
  const s = raw as Record<string, unknown>;
  const at = typeof s.at === "string" && /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}/.test(s.at) ? s.at.slice(0, 16) : null;
  if (!at) return null;
  const repeat = ["none", "daily", "weekdays", "weekly", "custom"].includes(String(s.repeat)) ? s.repeat as RoutedSchedule["repeat"] : "none";
  const days = Array.isArray(s.days)
    ? [...new Set(s.days.map(Number).filter((d) => Number.isInteger(d) && d >= 0 && d <= 6))]
    : [];
  const text = typeof s.text === "string" && s.text.trim() ? s.text.trim().slice(0, 200) : null;
  const label = typeof s.label === "string" && s.label.trim() ? s.label.trim().slice(0, 60) : "Your drop";
  const also = Array.isArray(s.also)
    ? [...new Set(
      s.also.filter((t): t is string => typeof t === "string" && /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}/.test(t))
        .map((t) => t.slice(0, 16)),
    )].filter((t) => t !== at).slice(0, 10)
    : [];
  return { at, also, repeat, days, text, label, settled: s.settled === true };
}
