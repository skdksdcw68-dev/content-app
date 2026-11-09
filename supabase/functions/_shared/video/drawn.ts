/**
 * Code-drawn videos: Stickman Showdown and Glow Explainer.
 *
 * No picture or video model draws these. The writer (a language model) only
 * chooses WORDS and a short list of things to show, from a fixed vocabulary;
 * the renderer (renderer/draw/) draws every frame in code and times each
 * thing to the word the voice says. So a clip costs the writer, the voice and
 * a few minutes of render CPU.
 *
 * This file holds what the server and the renderer both need: the plan shapes,
 * the checks that repair a plan instead of failing it, and the writer prompts.
 * Nothing here guesses what a person meant; the model does, and the checks
 * only keep its answer inside what the renderer can draw.
 */
import type { Issue, Parsed, WordTiming } from "./types.ts";

// ------------------------------------------------------------ Stickman showdown

/** What the writer decides: the words on screen and who wins. */
export interface ShowdownBrief {
  /** Private title for the library. */
  title: string;
  /** Up to 3 labels, in the order they give up. UPPER CASE, one word each. */
  losers: string[];
  /** The label of the one left standing. */
  winner: string;
  /** Index (0-based) of the loser that kicks its legs when nearly spent. */
  kicker?: number;
  /** The post's caption text. */
  caption: string;
}

export interface ShowdownFigure {
  label: string;
  dropS: number;
  tiredS?: [number, number];
  kick?: boolean;
}

/** What the renderer draws. */
export interface ShowdownPlan {
  durationS: number;
  fps: number;
  losers: ShowdownFigure[];
  winner: string;
  /** When the music drops and the winner is revealed. */
  beatS: number;
}

const word = (v: unknown, max = 14) => String(v ?? "").toUpperCase().replace(/[^A-Z0-9 &'-]/g, "").trim().slice(0, max);

export function parseShowdownBrief(raw: unknown): Parsed<ShowdownBrief> {
  const issues: Issue[] = [];
  const o = (raw ?? {}) as Record<string, unknown>;
  const losers = (Array.isArray(o.losers) ? o.losers : []).map((l) => word(l)).filter(Boolean).slice(0, 3);
  const winner = word(o.winner);
  if (losers.length === 0) issues.push({ path: "losers", message: "needs at least one loser", level: "error" });
  if (!winner) issues.push({ path: "winner", message: "needs a winner", level: "error" });
  if (winner && losers.includes(winner)) issues.push({ path: "winner", message: "the winner repeats a loser", level: "error" });
  if (issues.some((i) => i.level === "error")) return { ok: false, issues };
  const kicker = Number.isInteger(o.kicker) && (o.kicker as number) >= 0 && (o.kicker as number) < losers.length ? (o.kicker as number) : undefined;
  return {
    ok: true,
    issues,
    value: { title: String(o.title ?? "Showdown").slice(0, 80), losers, winner, kicker, caption: String(o.caption ?? "").slice(0, 400) },
  };
}

/** Drop times from the music's drop: the losers fall in turn across the first
 *  95% of the time before it, the same rhythm as the first preview (4.4, 8.4,
 *  12.9 s before a 13.6 s drop). */
export function planShowdown(brief: ShowdownBrief, beatS = 13.6, fps = 60): ShowdownPlan {
  const n = brief.losers.length;
  const losers = brief.losers.map((label, i): ShowdownFigure => {
    const share = n === 1 ? 0.65 : 0.32 + (0.63 * i) / (n - 1);
    const dropS = Math.round(beatS * share * 10) / 10;
    return { label, dropS, tiredS: [Math.round((0.3 + i * 1.1) * 10) / 10, dropS], kick: brief.kicker === i };
  });
  return { durationS: Math.round((beatS + 6.4) * 10) / 10, fps, losers, winner: brief.winner, beatS };
}

export const SHOWDOWN_WRITER_PROMPT = `You write the words for a "Stickman Showdown" short video.

WHAT IT IS: black screen, white stick figures hang from bars and do pull-ups. Each has one bold label. They get tired (arms turn red) and drop one by one. The music drops and the camera whips to one last figure nobody saw coming, glowing, still going. No voice, no sentences: the labels are the whole script, so the idea has to land from a few words alone.

HOW TO CHOOSE THE LABELS
- Each label is ONE upper-case word (two at most) that people recognise in themselves: MOTIVATION, EGO, TALENT, LUCK, HYPE, COMFORT, DISCIPLINE, CONSISTENCY, OBSESSION.
- The LOSERS are things most people rely on that run out under pressure, in the order they quit. 1 to 3 of them.
- The WINNER is the quality that lasts when the others are gone. It is the message of the video. It should feel earned, not generic.
- Fit the person: use what you know about them (niche, audience, what they post about) so the video is about THEIR topic when it makes sense. If they asked for a theme, the labels must carry it.
- Never copy another creator's exact sequence of labels; make a fresh idea.

Reply with JSON only:
{"title": "...", "losers": ["MOTIVATION","EGO","DISCIPLINE"], "winner": "OBSESSION", "kicker": 1, "caption": "post text, one or two short lines, no hashtags unless asked"}
"kicker" is the index of the loser that kicks its legs at the end (optional).`;

// -------------------------------------------------------------- Glow explainer
//
// Studied from the viral references (8 Nov 2026): 16:9, black, every scene a
// FULL-FRAME little world drawn in white line and glow (a hill and a flag, a
// night town with a person holding an idea, a globe, a staircase, a phone feed,
// a machine of gears), with stars/dust, light blooms, a ground line, and a
// camera that keeps moving between scenes. A new picture every 5 to 8 seconds,
// smooth and fast. No boxes stacked on empty black.
// So the writer picks one SCENE KIND per part of the script and fills a few
// words; the engine draws the world and times it to the narration.

export type IconName = "person" | "phone" | "coin" | "gear" | "globe" | "rocket" | "bulb" | "graph" | "stairs" | "lock" | "heart" | "clock" | "dice" | "cube";
export type CurveShape = "rise" | "flat" | "late_jump" | "fall" | "wobble_up" | "straight";
export type SceneKind = "journey" | "stairs" | "feed" | "grid" | "machine" | "hub" | "compare" | "venn" | "globe" | "crowd" | "chart" | "night";

export const ICONS: IconName[] = ["person", "phone", "coin", "gear", "globe", "rocket", "bulb", "graph", "stairs", "lock", "heart", "clock", "dice", "cube"];
export const CURVES: CurveShape[] = ["rise", "flat", "late_jump", "fall", "wobble_up", "straight"];
export const KINDS: SceneKind[] = ["journey", "stairs", "feed", "grid", "machine", "hub", "compare", "venn", "globe", "crowd", "chart", "night"];

/** A small pill that pops on a word of the scene's narration. */
export interface GlowLabel { on: string; text: string }
/** A big number that counts while the narrator speaks. */
export interface GlowNumber { on: string; until: string; from: number; to: number; prefix?: string; suffix?: string; label?: string }

export interface GlowScene {
  /** The part of the narration spoken in this scene. The scenes' texts, joined
   *  in order, ARE the script the voice reads. */
  text: string;
  kind: SceneKind;
  /** 0 to 4 pills, each on a word of `text`. */
  labels: GlowLabel[];
  number?: GlowNumber;
  /** journey: caption under the walker ("SOMEONE"). night: caption on the moon. */
  who?: string;
  /** journey: the flag's label. globe: the line above it. crowd: the goal. */
  goal?: string;
  /** feed: the phone's header ("WEEK 4"). grid: caption. machine: caption. hub: centre. venn: middle. */
  title?: string;
  /** stairs: "up" climbs, "down" is a staircase going down. */
  direction?: "up" | "down";
  /** grid: cards (4-16). crowd: people (3-12). */
  count?: number;
  /** grid, crowd: the index that is lit and special. */
  hot?: number;
  /** hub: spoke labels. machine: the parts it makes. venn: circle labels. compare: the two sides. */
  items?: string[];
  /** One icon per item (hub, compare, machine). */
  icons?: IconName[];
  /** chart: 1 or 2 lines. */
  lines?: Array<{ label: string; shape: CurveShape }>;
}

export interface GlowPlan {
  title: string;
  caption: string;
  scenes: GlowScene[];
}

const str = (v: unknown, max: number) => String(v ?? "").replace(/\s+/g, " ").trim().slice(0, max);
const up = (v: unknown, max: number) => str(v, max).toUpperCase();
const num = (v: unknown, lo: number, hi: number, dflt: number) => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : dflt;
};
export const wordsOf = (text: string) => text.split(/\s+/).filter(Boolean);
const clean = (w: string) => w.toLowerCase().replace(/[^\p{L}\p{N}$%]/gu, "");

/** Keeps a plan inside what the renderer can draw. A bad detail is repaired or
 *  dropped with a note (the video still works); a plan with fewer than 3
 *  usable scenes fails. */
export function parseGlowPlan(raw: unknown): Parsed<GlowPlan> {
  const issues: Issue[] = [];
  const o = (raw ?? {}) as Record<string, unknown>;
  const scenes: GlowScene[] = [];
  (Array.isArray(o.scenes) ? o.scenes : []).slice(0, 120).forEach((s, si) => {
    const sc = (s ?? {}) as Record<string, unknown>;
    const text = str(sc.text, 1200);
    const at = `scenes[${si}]`;
    if (wordsOf(text).length < 3) { issues.push({ path: `${at}.text`, message: "scene has no narration", level: "warning" }); return; }
    let kind = sc.kind as SceneKind;
    if (!KINDS.includes(kind)) {
      issues.push({ path: `${at}.kind`, message: `unknown kind "${String(sc.kind)}", drawn as a journey`, level: "warning" });
      kind = "journey";
    }
    const labels: GlowLabel[] = (Array.isArray(sc.labels) ? sc.labels : []).slice(0, 4).map((l) => {
      const b = (l ?? {}) as Record<string, unknown>;
      return { on: str(b.on, 40), text: up(b.text, 30) };
    }).filter((l) => l.text);
    const scene: GlowScene = { text, kind, labels };
    const n = sc.number as Record<string, unknown> | undefined;
    if (n && typeof n === "object") {
      scene.number = {
        on: str(n.on, 40), until: str(n.until, 40) || str(n.on, 40), from: num(n.from, -1e12, 1e12, 0), to: num(n.to, -1e12, 1e12, 100),
        prefix: String(n.prefix ?? "").slice(0, 5), suffix: String(n.suffix ?? "").slice(0, 6), label: n.label ? up(n.label, 28) : undefined,
      };
    }
    if (sc.who) scene.who = up(sc.who, 24);
    if (sc.goal) scene.goal = up(sc.goal, 26);
    if (sc.title) scene.title = up(sc.title, 28);
    if (sc.direction === "up" || sc.direction === "down") scene.direction = sc.direction;
    if (sc.count !== undefined) scene.count = Math.round(num(sc.count, 3, 16, 9));
    if (sc.hot !== undefined) scene.hot = Math.round(num(sc.hot, 0, 15, 0));
    if (Array.isArray(sc.items)) scene.items = sc.items.slice(0, 4).map((i) => up(i, 22)).filter(Boolean);
    if (Array.isArray(sc.icons)) scene.icons = sc.icons.filter((i): i is IconName => ICONS.includes(i as IconName)).slice(0, 4);
    if (Array.isArray(sc.lines)) {
      scene.lines = sc.lines.slice(0, 2).map((l) => {
        const c = (l ?? {}) as Record<string, unknown>;
        return { label: up(c.label, 14), shape: CURVES.includes(c.shape as CurveShape) ? (c.shape as CurveShape) : "rise" };
      });
    }
    if ((kind === "hub" || kind === "venn" || kind === "compare") && (scene.items?.length ?? 0) < 2) {
      issues.push({ path: `${at}.items`, message: `${kind} needs 2 to 4 items; drawn as a journey`, level: "warning" });
      scene.kind = "journey";
    }
    scenes.push(scene);
  });
  if (scenes.length < 3) {
    issues.push({ path: "scenes", message: "needs at least 3 scenes with narration", level: "error" });
    return { ok: false, issues };
  }
  return { ok: true, issues, value: { title: str(o.title, 80) || "Explainer", caption: str(o.caption, 400), scenes } };
}

/** The narration the voice reads. */
export const glowScript = (plan: GlowPlan) => plan.scenes.map((s) => s.text).join(" ");

/** Word index (0-based, in the whole script) where each scene starts. */
export function sceneStarts(plan: GlowPlan): number[] {
  let n = 0;
  return plan.scenes.map((s) => { const at = n; n += wordsOf(s.text).length; return at; });
}

/** The word index an `on` word refers to: the first match in the scene's own
 *  words at or after `from`, else any match in the scene, else the scene's
 *  first word. */
export function cueIndex(plan: GlowPlan, scene: number, on: string, from: number): number {
  const start = sceneStarts(plan)[scene]!;
  const ws = wordsOf(plan.scenes[scene]!.text);
  const target = clean(on);
  if (target) {
    for (let i = Math.max(0, from - start); i < ws.length; i++) if (clean(ws[i]!) === target) return start + i;
    for (let i = 0; i < ws.length; i++) if (clean(ws[i]!) === target) return start + i;
  }
  return Math.max(start, from);
}

/** Time of a word in the voice's own timings (clamped to what exists). */
export function cueTime(words: WordTiming[], index: number): { s: number; e: number } {
  const w = words[Math.max(0, Math.min(index, words.length - 1))]!;
  return { s: w.startS, e: w.endS };
}

export const GLOW_WRITER_PROMPT = `You write "Glow Explainer" videos: a calm narrator explains one idea while a little world is drawn on a black 16:9 screen in white line and glow, one scene per part of the script. It is the look of the viral money/mindset explainers: a person with a glowing idea, a hill and a flag, a night town, a globe, a staircase, a phone feed, a machine of gears. The camera never rests, the pace is fast and smooth, and every frame is full. There are no photos, no subtitles; the only words on screen are tiny pills and numbers.

THE SCRIPT (what the narrator says)
- 170 to 230 words for a 60 to 80 second video (about 2.8 words per second). Longer if asked: add scenes, not speed. Plain, warm, slightly provocative, short sentences. No hashtags, no emojis, no stage directions.
- Shape: a counter-intuitive claim that stops the scroll -> what most people believe -> "Imagine someone..." a small story -> "But here's what they can't see" -> the mechanism (why it really works) -> one reframing last line.
- Write about the person's own world (niche, audience, goal) when you know it, or the idea they asked for. Original sentences only: copy the structure of viral explainers, never their words.
- Never present an invented statistic as research. Round, illustrative numbers are fine when the story is clearly an example.

THE SCENES
Split the script into SHORT scenes: a new picture every 5 to 8 seconds (10 to 22 words each), so 9 to 13 scenes for a minute. Each scene is {"text": its part of the script (the scenes' texts joined are the whole script, word for word), "kind": one of the kinds below, "labels": [up to 4 pills {"on": ONE word of that scene's text, "text": "2-4 WORDS UPPER CASE"}], plus the kind's fields}. A pill pops when its word is said, so put it on the word that names it. Optional "number": {"on": word, "until": later word, "from": 0, "to": 10000, "prefix": "$", "suffix": "", "label": "SMALL LABEL"} counts up while the narrator speaks.
KINDS (pick the right picture for the sentence, and vary them; never the same kind twice in a row):
- journey: a person walks along a horizon toward a flag. {"who": "SOMEONE", "goal": "$10,000"}. For a goal, a long road, effort, a slow start.
- stairs: a huge staircase fills the frame; a person at its foot or top. {"direction": "up" or "down"}. For growth that compounds, or a fall.
- feed: a phone with posts and likes; paper planes fly. {"title": "WEEK 4"}. For posting, attention, silence, then a spike (add a number counting the likes).
- grid: a wall of cards, one lights up and grows. {"count": 9, "hot": 4, "title": "THE POST THAT WORKED"}. For many tries and the one that hit.
- machine: gears turning in a box that outputs parts. {"title": "BUILDING THE MACHINE", "items": ["A PRODUCT","A PROCESS"], "icons": ["cube","gear"]}. For a system, a process, what gets built.
- hub: a circle in the middle with spokes to 2-4 reasons. {"title": "REASON", "items": ["CONVENIENCE","TIME SAVED","CERTAINTY"], "icons": ["bulb","clock","lock"]}.
- compare: two things side by side with a meter each. {"items": ["COMPLEX","SIMPLE"], "icons": ["gear","coin"]}. For effort vs value, before vs after.
- venn: 2 or 3 overlapping circles. {"items": ["WANTS","FRUSTRATIONS","WILLING TO PAY"], "title": "OPPORTUNITY"}. For where ideas meet.
- globe: one glowing person on top of a huge world, camera pulling out. {"goal": "1 OF 8,000,000,000", "title": "STILL BELIEVES IN IT"}. For being alone, scale, rarity.
- crowd: a row of people under a goal, one lit and the others dim. {"count": 8, "hot": 3, "goal": "$1,000,000"}. For "most people vs the few".
- chart: axes with 1 or 2 lines. {"lines": [{"label": "SKILL", "shape": "rise"}, {"label": "RESULTS", "shape": "late_jump"}]} shapes: rise, flat, late_jump, fall, wobble_up, straight. For anything that changes over time.
- night: a town at night, a person holding a glowing idea, street lamps, a moon. {"who": "THAT NIGHT"}. For a quiet human moment, doubt, a decision.
Always give each scene its kind's fields. Use at least two scenes with a "number". End on a scene whose pill carries the key words of the closing line.

Reply with JSON only: {"title":"...","caption":"post text, one or two short lines","scenes":[{"text":"...","kind":"journey","who":"SOMEONE","goal":"$10,000","labels":[{"on":"word","text":"A STRAIGHT LINE"}]}, ...]}`;
