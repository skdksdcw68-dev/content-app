import type { Issue, StoryPlan } from "./types.ts";
import { parseStoryPlan } from "./storyboard.ts";
import type { Production } from "./style.ts";

/**
 * Asks a model for the production plan and does not accept it until it parses.
 *
 * `ask` is whatever calls the model (the Claude writer in production, a stub in
 * tests). A reply that is not valid JSON, or that fails the plan's own checks,
 * is sent back with the exact list of problems, up to `retries` times -- an
 * invalid plan never reaches the stages that spend money.
 */
/** The most words a narration may have for a video of this length.
 *
 * Abel, 31 Oct 2026: "If the user says 'Generate 15 seconds,' make sure it's
 * only 15 seconds." The planner was told "about 2.4 words a second" and wrote
 * 43 words for 15 s; the storyteller read them in 20.7 s (2.1 a second), and
 * the video came out 21 s. So the budget is set from what a narrator really
 * reads, minus the tail the last word needs, and it is a ceiling, not a
 * target. A little over is caught by speeding the voice up (story.ts); a lot
 * over is sent back to the planner. */
export function wordBudget(durationS: number, wordsPerS = 2.2): number {
  const rate = Number.isFinite(wordsPerS) && wordsPerS >= 1.5 && wordsPerS <= 4 ? wordsPerS : 2.2;
  return Math.max(6, Math.floor(Math.max(1, durationS - 0.6) * rate));
}

/** What keeps two videos from being the same video (Abel, 10 Nov 2026: "make
 *  sure not to give everyone the same idea"): what this person already got, a
 *  fresh handful from the format's idea bank, and a hero drawn from its cast. */
export interface Variety {
  recent?: string[];
  ideas?: string[];
  hero?: string | null;
}

export type PlanRequest = { topic: string; brandContext?: string; direction?: string; avoid?: string } & Variety;

/** Words in a narration, counted the way a voice reads them. */
export function wordCount(text: string): number {
  return text.split(/\s+/).filter((w) => /[\p{L}\p{N}]/u.test(w)).length;
}

/** The planner's master prompt. The fixed text lives on the server (table
 *  master_prompts, key "story_planner") so it can be improved without an app
 *  update; this copy is the fallback and the seed. The {{...}} parts are filled
 *  from the production's numbers, which only code can compute. */
export const DEFAULT_PLANNER_TEMPLATE = [
  "You are the planner for a short-form video studio. You return ONE JSON object and nothing else.",
  "",
  "Shape:",
  '{"title":string,"hook":string,"script":string,',
  ' "characters":[{"name":string,"description":string}],',
  ' "locations":[{"name":string,"description":string}],',
  ' "musicBrief":string,',
  ' "scenes":[{"id":string,"narration":string,"visual":string,"imagePrompt":string,"motionPrompt":string,',
  '   "motion":"none|push_in|pull_out|pan_left|pan_right","transition":"cut|fade",',
  '   "characters":[string],"location":string,"emphasis":[string],"sfx":[string]}]}',
  "",
  "Rules:",
  "{{narration_rule}}",
  "{{narration_script_rule}}",
  "{{scene_rule}}",
  "- `imagePrompt` describes ONE still: subject, setting, light, composition, vertical 9:16 framing. No on-image text, logos or watermarks.",
  "- Describe a recurring person or place once in `characters` / `locations` and refer to them by name in `characters` / `location` on each scene. Repeat the key visual details in each imagePrompt so the same person looks the same.",
  "- `motionPrompt` says what moves over the scene (camera and subject), in one sentence, and ends by keeping the subject's appearance unchanged.",
  "- Never invent statistics, quotes, dates or events and present them as real. If the topic needs a fact you were not given, tell it as a story or an open question.",
  "- Visual style: {{visual_style}}.",
  "{{music}}",
  "{{style_rules}}",
].join("\n");

export function plannerPrompt(
  p: Production,
  request: PlanRequest,
  template?: string | null,
): {
  system: string;
  user: string;
} {
  const words = wordBudget(p.durationS, p.wordsPerS);
  const rate = String(p.wordsPerS ?? 2.2);
  const fill: Record<string, string> = {
    narration_rule: p.narration
      ? `- The video is ${p.durationS} seconds, and that is a hard limit. The whole narration is AT MOST ${words} words -- count them before you answer. A narrator reads about ${rate} words a second, so every extra word makes the video longer than the person asked for. Short, punchy sentences.`
      : `- The video is ${p.durationS} seconds, and that is a hard limit.`,
    narration_script_rule: p.narration
      ? "- Every scene's `narration` is exactly what the narrator says over it, in order; read together they are `script`."
      : "- There is no narrator. Leave `narration` empty; put any words that must appear on screen in `visual`.",
    scene_rule: `- Aim for scenes of about ${p.sceneS} seconds each, so roughly ${Math.max(2, Math.round(p.durationS / p.sceneS))} scenes. The first scene is the hook and must land in the first 3 seconds.`,
    visual_style: p.visualStyle || "cinematic, consistent across all scenes",
    music: p.musicBrief ? `- Music mood to put in musicBrief: ${p.musicBrief}.` : "- No music: leave musicBrief empty.",
    style_rules: p.writerRules ? `\nThis style's own rules (follow them as closely as the rules above):\n${p.writerRules}` : "",
  };
  const system = (template && template.includes("{{") ? template : DEFAULT_PLANNER_TEMPLATE)
    .replace(/\{\{(\w+)\}\}/g, (_m, k: string) => fill[k] ?? "");

  const user = [
    `Topic: ${request.topic}`,
    // Their profile is background, not the subject (Abel, 10 Nov 2026: every
    // video of a designer's account came out about designers, whatever was asked).
    request.brandContext
      ? `Who asked (background only): ${request.brandContext}. Use this ONLY when the topic itself is about their own brand, product or work. Otherwise ignore it completely: do not mention their job, niche, product or audience, and do not bend the topic toward them.`
      : "",
    request.ideas?.length
      ? `IDEA BANK (a fresh handful). If the topic above is only the name of a format or says "any" / "surprise me" and gives no real subject, choose ONE of these or invent a new one of the same quality. If the topic has a real subject, ignore this list:\n${request.ideas.map((i) => `- ${i}`).join("\n")}`
      : "",
    request.hero
      ? `Hero for this video (use this person as the main character unless the topic names or clearly needs someone else): ${request.hero}`
      : "",
    request.recent?.length
      ? `This person's recent videos. Do NOT repeat any of them: pick a different subject, a different kind of opening line, a different setting and a different hero:\n${request.recent.map((r) => `- ${r}`).join("\n")}`
      : "",
    request.direction ? `Direction from the person (follow it, but add no facts of your own): ${request.direction}` : "",
    request.avoid ? `Avoid: ${request.avoid}` : "",
  ].filter(Boolean).join("\n");
  return { system, user };
}

export interface PlanResult {
  plan: StoryPlan | null;
  issues: Issue[];
  attempts: number;
}

export async function planStory(args: {
  production: Production;
  request: PlanRequest;
  ask(system: string, user: string): Promise<string>;
  retries?: number;
  /** The master prompt from the server (master_prompts); the built-in one when absent. */
  template?: string | null;
}): Promise<PlanResult> {
  const { system, user } = plannerPrompt(args.production, args.request, args.template);
  const limit = (args.retries ?? 2) + 1;
  let prompt = user;
  let issues: Issue[] = [];
  const budget = wordBudget(args.production.durationS, args.production.wordsPerS);
  // The plan nearest the budget among those that failed ONLY on length: if
  // every try misses, it is used anyway (a long one has its voice sped up to
  // fit) rather than giving up on a good story over a few words.
  let longest: { plan: StoryPlan; words: number; issues: Issue[] } | null = null;

  for (let n = 1; n <= limit; n++) {
    const reply = await args.ask(system, prompt);
    const json = extractJson(reply);
    if (json === null) {
      issues = [{ path: "", message: "the reply was not valid JSON", level: "error" }];
    } else {
      const parsed = parseStoryPlan(json);
      issues = parsed.issues;
      if (parsed.ok && !parsed.issues.some((i) => i.level === "error")) {
        const said = args.production.narration
          ? wordCount(parsed.value.scenes.map((s) => s.narration).join(" "))
          : 0;
        // A tenth over still fits once the voice is a touch faster; under
        // four fifths leaves the video short of what was asked.
        const tooShort = args.production.narration && said < Math.floor(budget * 0.8);
        if (said <= Math.ceil(budget * 1.1) && !tooShort) {
          return { plan: parsed.value, issues: parsed.issues, attempts: n };
        }
        const tooLong: Issue = {
          path: "narration",
          message: tooShort
            ? `the narration is only ${said} words; a ${args.production.durationS}-second video needs about ${budget}. Write ${Math.floor(budget * 0.85)} to ${budget} words`
            : `the narration is ${said} words; a ${args.production.durationS}-second video has room for ${budget}. Cut it to ${budget} words or fewer and keep the story`,
          level: "error",
        };
        if (!longest || Math.abs(said - budget) < Math.abs(longest.words - budget)) {
          longest = { plan: parsed.value, words: said, issues: [...parsed.issues, { ...tooLong, level: "warning" }] };
        }
        issues = [...parsed.issues, tooLong];
      }
    }
    // Tell the model what was wrong with its own answer.
    prompt = `${user}\n\nYour previous answer was rejected:\n${
      issues.filter((i) => i.level === "error").map((i) => `- ${i.path || "reply"}: ${i.message}`).join("\n")
    }\nReturn the corrected JSON object only.`;
  }
  if (longest) return { plan: longest.plan, issues: longest.issues, attempts: limit };
  return { plan: null, issues, attempts: limit };
}

/** The first balanced JSON object in a reply, tolerating a code fence or a
 *  sentence before it. Null when there is none. */
export function extractJson(reply: string): unknown | null {
  const start = reply.indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < reply.length; i++) {
    const c = reply[i]!;
    if (inString) {
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') inString = true;
    else if (c === "{") depth++;
    else if (c === "}" && --depth === 0) {
      try {
        return JSON.parse(reply.slice(start, i + 1));
      } catch {
        return null;
      }
    }
  }
  return null;
}
