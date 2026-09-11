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
  | "explain";    // what do you know, what did you do, why

const INTENTS: Intent[] = ["chat", "plan", "revise", "make", "research", "export", "explain"];

export interface Routed {
  intent: Intent;
  /** How many days of content, when the request implies a stretch. */
  days: number | null;
  /** The router's one-line reading of the request, for the trail. */
  reading: string;
  /** For `make`: what kind of thing. Null when the request does not say, and
   *  then it is video, because that is what this product posts. */
  media: "image" | "video" | null;
  /** For `export`: which file. Null when not named. */
  format: "docx" | "pdf" | "zip" | null;
}

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
export async function route(message: string, apiKey: string): Promise<Routed> {
  const system = [
    "Classify one message from someone running a social media account. JSON only.",
    '{"intent":"chat|plan|revise|make|research|export|explain","days":number|null,' +
    '"media":"image|video"|null,"format":"docx|pdf|zip"|null,"reading":string}',
    "",
    "plan     — wants content planned across a stretch of days.",
    "revise   — wants something that already exists changed.",
    "make     — wants an image or a video generated now.",
    "research — wants something looked into properly: a market, competitors, trends, an audience.",
    "export   — wants something from this conversation as a file: a document, a PDF, a zip.",
    "explain  — asking what you know, what you did, or why.",
    "chat     — anything else, including greetings, questions about you, and writing captions or hooks.",
    "",
    "days: only when a stretch is implied. 'a month' is 30, 'next week' is 7.",
    "media: for make only. 'image' for a picture, photo, thumbnail, poster; 'video' for a clip, reel, video; null if unsaid.",
    "format: for export only. 'docx' for Word or a document, 'pdf' for PDF, 'zip' for everything or a package.",
    "reading: one short sentence, in your own words, of what they are asking for.",
  ].join("\n");

  try {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: MODELS.fast,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: system },
          { role: "user", content: message },
        ],
      }),
    });

    if (!response.ok) return fallback(message);

    const body = await response.json();
    const parsed = JSON.parse(body.choices?.[0]?.message?.content ?? "{}");
    const intent = parsed?.intent;

    return {
      intent: INTENTS.includes(intent) ? intent : "chat",
      days: typeof parsed?.days === "number" && parsed.days > 0
        ? Math.min(Math.round(parsed.days), 30)
        : null,
      reading: typeof parsed?.reading === "string" ? parsed.reading : message.slice(0, 80),
      media: parsed?.media === "image" || parsed?.media === "video" ? parsed.media : null,
      format: ["docx", "pdf", "zip"].includes(parsed?.format) ? parsed.format : null,
    };
  } catch {
    return fallback(message);
  }
}

function fallback(message: string): Routed {
  return { intent: "chat", days: null, reading: message.slice(0, 80), media: null, format: null };
}
