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
export function plannerPrompt(p: Production, request: { topic: string; brandContext?: string; avoid?: string }): {
  system: string;
  user: string;
} {
  const words = Math.round(p.durationS * 2.4);
  const system = [
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
    `- The video is about ${p.durationS} seconds. The narration is about ${words} words in total (a person speaks ~2.4 words a second); the real voice, not you, decides the final timing.`,
    p.narration
      ? "- Every scene's `narration` is exactly what the narrator says over it, in order; read together they are `script`."
      : "- There is no narrator. Leave `narration` empty; put any words that must appear on screen in `visual`.",
    `- Aim for scenes of about ${p.sceneS} seconds each, so roughly ${Math.max(2, Math.round(p.durationS / p.sceneS))} scenes. The first scene is the hook and must land in the first 3 seconds.`,
    "- `imagePrompt` describes ONE still: subject, setting, light, composition, vertical 9:16 framing. No on-image text, logos or watermarks.",
    "- Describe a recurring person or place once in `characters` / `locations` and refer to them by name in `characters` / `location` on each scene. Repeat the key visual details in each imagePrompt so the same person looks the same.",
    "- `motionPrompt` says what moves over the scene (camera and subject), in one sentence, and ends by keeping the subject's appearance unchanged.",
    "- Never invent statistics, quotes, dates or events and present them as real. If the topic needs a fact you were not given, tell it as a story or an open question.",
    `- Visual style: ${p.visualStyle || "cinematic, consistent across all scenes"}.`,
    p.musicBrief ? `- Music mood to put in musicBrief: ${p.musicBrief}.` : "- No music: leave musicBrief empty.",
  ].join("\n");

  const user = [
    `Topic: ${request.topic}`,
    request.brandContext ? `About the account: ${request.brandContext}` : "",
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
  request: { topic: string; brandContext?: string; avoid?: string };
  ask(system: string, user: string): Promise<string>;
  retries?: number;
}): Promise<PlanResult> {
  const { system, user } = plannerPrompt(args.production, args.request);
  const limit = (args.retries ?? 2) + 1;
  let prompt = user;
  let issues: Issue[] = [];

  for (let n = 1; n <= limit; n++) {
    const reply = await args.ask(system, prompt);
    const json = extractJson(reply);
    if (json === null) {
      issues = [{ path: "", message: "the reply was not valid JSON", level: "error" }];
    } else {
      const parsed = parseStoryPlan(json);
      issues = parsed.issues;
      if (parsed.ok && !parsed.issues.some((i) => i.level === "error")) {
        return { plan: parsed.value, issues: parsed.issues, attempts: n };
      }
    }
    // Tell the model what was wrong with its own answer.
    prompt = `${user}\n\nYour previous answer was rejected:\n${
      issues.filter((i) => i.level === "error").map((i) => `- ${i.path || "reply"}: ${i.message}`).join("\n")
    }\nReturn the corrected JSON object only.`;
  }
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
