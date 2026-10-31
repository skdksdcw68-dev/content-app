import type { Aspect } from "./types.ts";
import type { CaptionTheme } from "./captions.ts";
import { THEMES } from "./captions.ts";

/**
 * How one content style (a `content_templates` row, migration 0058) controls
 * the production, not only the script.
 *
 * Nothing here invents a style: it reads the `workflow` each existing style
 * already carries (format, voice, text, music, shots, duration_s) and turns it
 * into the choices the engine acts on. A new style needs a row, not code.
 */
export interface StyleRow {
  slug: string;
  name?: string;
  visual_style?: string | null;
  workflow?: {
    format?: string;
    voice?: string;
    text?: string;
    music?: string;
    shots?: number;
    duration_s?: number;
    structure?: string[];
  } | null;
}

export type Support =
  | { level: "full" }
  /** Runs, but part of what the style describes cannot be produced. */
  | { level: "partial"; reason: string }
  /** The engine cannot make this format; say so instead of faking it. */
  | { level: "unsupported"; reason: string };

export interface Production {
  slug: string;
  support: Support;
  aspect: Aspect;
  durationS: number;
  /** Narrator speaks over the picture. */
  narration: boolean;
  /** Captions from the voice's word timings; big on-screen text is a
   *  different overlay and is reported as partial until built. */
  captions: { enabled: boolean; theme: CaptionTheme; themeName: "clean" | "bold" | "horror" };
  /** Words for the music generator, or null for no music. */
  musicBrief: string | null;
  /** Target average scene length; the planner aims at it, the voice decides. */
  sceneS: number;
  defaultTransition: "cut" | "fade";
  visualStyle: string;
  notes: string[];
}

const DARK = /^(scary|mystery|horror|creepy|unsolved)/;

export function productionFor(
  style: StyleRow,
  overrides: { aspect?: Aspect; durationS?: number; narration?: boolean } = {},
): Production {
  const w = style.workflow ?? {};
  const notes: string[] = [];
  const format = w.format ?? "narrated";

  let support: Support = { level: "full" };
  if (format === "talking_head" || w.voice === "on_camera") {
    support = {
      level: "unsupported",
      reason: "this style needs a person speaking on camera; an image-and-voice engine would only fake it",
    };
  } else if (format === "demo") {
    support = { level: "unsupported", reason: "this style needs real screen recordings of the product" };
  } else if (w.text === "big_text") {
    support = { level: "partial", reason: "the style's big on-screen text lines are not built yet; captions are used instead" };
  }

  const durationS = overrides.durationS ?? w.duration_s ?? 30;
  const wantsVoice = w.voice === "narration";
  const narration = overrides.narration ?? wantsVoice;
  if (overrides.narration === false && wantsVoice) notes.push("narration switched off by the user; captions carry the words");

  // "Trending" is a platform's music library, which is licensed for use inside
  // that platform only. Generate to the mood instead.
  let music = (w.music ?? "").trim();
  let musicBrief: string | null = music && music !== "none" ? music : null;
  if (musicBrief && /trending/i.test(musicBrief)) {
    musicBrief = musicBrief.replace(/trending( sound)?( or none)?,?\s*/i, "").trim() || "upbeat, light";
    notes.push("trending sounds are platform-licensed and are not used; the music is generated to the same mood");
  }
  music = musicBrief ?? "";

  const shots = typeof w.shots === "number" && w.shots > 0 ? w.shots : Math.max(4, Math.round(durationS / 5));
  // A still held longer than ~5 s with a slow zoom feels dead, whatever the
  // style's `shots` (written for single video clips) works out to.
  const sceneS = Math.min(5, Math.max(2, Math.round((durationS / shots) * 10) / 10));

  const themeName = DARK.test(style.slug) ? "horror" : w.text === "big_text" ? "bold" : "clean";
  return {
    slug: style.slug,
    support,
    aspect: overrides.aspect ?? "9:16",
    durationS,
    narration,
    captions: { enabled: w.text !== "none" || narration, theme: THEMES[themeName]!, themeName },
    musicBrief,
    sceneS,
    // Quick cuts for fast pacing, soft fades when each image has time to breathe.
    defaultTransition: sceneS >= 5 ? "fade" : "cut",
    visualStyle: (style.visual_style ?? "").trim(),
    notes,
  };
}
