/**
 * The data every stage of the video engine passes to the next.
 *
 * Nothing in this folder talks to a provider, a database or a process by
 * itself. Each module takes plain data and returns plain data, so the same
 * code runs in an Edge Function (planning, review decisions), in the render
 * worker (ffmpeg) and under `deno test` -- and a stage can be re-run from its
 * persisted input without the stages before it.
 */

export type Aspect = "9:16" | "16:9" | "1:1";

export const FRAME: Record<Aspect, { width: number; height: number }> = {
  "9:16": { width: 1080, height: 1920 },
  "16:9": { width: 1920, height: 1080 },
  "1:1": { width: 1080, height: 1080 },
};

/** One spoken word with the time it is actually said, from the voice
 *  provider's alignment or a transcription of the real audio. Never derived
 *  from character counts. */
export interface WordTiming {
  word: string;
  startS: number;
  endS: number;
}

export type Motion = "none" | "push_in" | "pull_out" | "pan_left" | "pan_right";
export type TransitionType = "cut" | "fade";

export interface Scene {
  id: string;
  order: number;
  /** The words the narrator says over this scene. Empty on a silent scene. */
  narration: string;
  /** What the picture shows: subject, setting, light. */
  visual: string;
  /** Written for the image model; kept apart from `motion` so the still can
   *  be reviewed before anything is animated. */
  imagePrompt: string;
  /** How the picture moves once animated: what the camera and subject do. */
  motionPrompt: string;
  motion: Motion;
  transition: TransitionType;
  /** Names from the plan's `characters` / `locations` lists, for continuity. */
  characters: string[];
  location: string | null;
  /** Words of the narration that deserve emphasis in the captions. */
  emphasis: string[];
  /** Sound effects wanted here, in words. */
  sfx: string[];
  /** Filled in once the voice exists. */
  durationS: number | null;
}

export interface StoryPlan {
  title: string;
  hook: string;
  script: string;
  /** Reference descriptions the image prompts keep re-using, so the same
   *  person looks like the same person. */
  characters: Array<{ name: string; description: string }>;
  locations: Array<{ name: string; description: string }>;
  musicBrief: string;
  scenes: Scene[];
}

export interface Issue {
  /** Where: "scenes[3].imagePrompt". */
  path: string;
  message: string;
  /** `error` stops the pipeline, `warning` is reported and carried on. */
  level: "error" | "warning";
}

export type Parsed<T> =
  | { ok: true; value: T; issues: Issue[] }
  | { ok: false; issues: Issue[] };

/** What a generation model can be asked for; the scene splitter respects it. */
export interface ClipLimits {
  /** Longest clip one request makes, seconds. */
  maxS: number;
  /** Shortest clip one request makes, seconds. */
  minS: number;
}
