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
  /** What the figures do. Pull-ups when absent. */
  activity?: ShowdownActivity;
  /** The contest the model designed, when activity is "custom". */
  custom?: ContestSpec;
}

export type ShowdownActivity = "pullup" | "plank" | "custom";

// ---- A contest the model designs itself (renderer/draw/contest.ts draws it).
// Side view, the figure faces right. x forward, y UP from the floor, pixels.
// Limb angles in degrees from straight down (+ = toward the front); torso from
// straight up (+ = leaning forward); elbow/knee angles are relative.
export type Angles = [number, number];
export interface ContestPose {
  hip?: [number, number];
  torso?: number;
  head?: number;
  armL?: Angles;
  armR?: Angles;
  legL?: Angles;
  legR?: Angles;
  /** Points on the floor (or a prop) the hands and feet are fixed to, in the
   *  same x/y as hip. A pinned limb ignores its angles: the elbow or knee bends
   *  by itself to reach the point. Use it for anything planted: push-ups,
   *  planks, sit-ups, hanging from a bar. */
  pin?: Partial<Record<"handL" | "handR" | "footL" | "footR", [number, number]>>;
  /** Which way the elbows and knees point when pinned: [arms, legs], each 1
   *  (forward) or -1 (backward). Default [-1, 1]. */
  bend?: [number, number];
}
export type PropAnchor = "floor" | "hip" | "neck" | "head" | "shoulder" | "handL" | "handR" | "footL" | "footR" | "kneeL" | "kneeR";
export interface ContestProp {
  shape: "line" | "rect" | "circle";
  a?: [number, number];
  b?: [number, number];
  x?: number;
  y?: number;
  w?: number;
  h?: number;
  r?: number;
  fill?: boolean;
  /** Line thickness. */
  w2?: number;
  attach?: PropAnchor;
  /** When the figure gives up, this prop falls to the floor. */
  failDrop?: boolean;
}
export interface ContestSpec {
  name: string;
  poses: Record<string, ContestPose>;
  /** Pose names in the order the figure loops through them; one name = a hold. */
  cycle?: string[];
  /** The pose a tired figure sags toward. */
  tired?: string;
  /** Seconds per repetition when fresh. */
  repS?: number;
  /** The pose after giving up, usually lying or sitting. */
  fail: { pose: ContestPose };
  props?: ContestProp[];
  /** Keep the lowest point on the floor (default true). False for jumps. */
  snap?: boolean;
}

const ANCHORS: PropAnchor[] = ["floor", "hip", "neck", "head", "shoulder", "handL", "handR", "footL", "footR", "kneeL", "kneeR"];
const n = (v: unknown, lo: number, hi: number): number | undefined => (typeof v === "number" && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : undefined);
const pair = (v: unknown, lo: number, hi: number): [number, number] | undefined => {
  if (!Array.isArray(v) || v.length < 2) return undefined;
  const a = n(v[0], lo, hi), b = n(v[1], lo, hi);
  return a === undefined || b === undefined ? undefined : [a, b];
};

function cleanPose(raw: unknown): ContestPose | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const pose: ContestPose = {};
  const hip = pair(o.hip, -600, 700);
  if (hip) pose.hip = [Math.min(600, hip[0]), Math.max(0, hip[1])];
  const torso = n(o.torso, -220, 220); if (torso !== undefined) pose.torso = torso;
  const head = n(o.head, -90, 90); if (head !== undefined) pose.head = head;
  const arm = pair(o.arm, -220, 220), armL = pair(o.armL, -220, 220), armR = pair(o.armR, -220, 220);
  if (armL ?? arm) pose.armL = (armL ?? arm)!;
  if (armR ?? arm) pose.armR = (armR ?? arm)!;
  const leg = pair(o.leg, -220, 220), legL = pair(o.legL, -220, 220), legR = pair(o.legR, -220, 220);
  if (legL ?? leg) pose.legL = (legL ?? leg)!;
  if (legR ?? leg) pose.legR = (legR ?? leg)!;
  if (o.pin && typeof o.pin === "object") {
    const pin: NonNullable<ContestPose["pin"]> = {};
    for (const k of ["handL", "handR", "footL", "footR"] as const) {
      const v = pair((o.pin as Record<string, unknown>)[k], -700, 700);
      if (v) pin[k] = [v[0], Math.max(-60, Math.min(700, v[1]))];
    }
    if (Object.keys(pin).length > 0) pose.pin = pin;
  }
  const bend = pair(o.bend, -1, 1);
  if (bend) pose.bend = [bend[0] < 0 ? -1 : 1, bend[1] < 0 ? -1 : 1];
  return pose;
}

/** A contest from whatever the model wrote, or null when it cannot be drawn
 *  (the caller then falls back to pull-ups). Everything is clamped, counted and
 *  checked so a bad answer can never crash a render. */
export function parseContest(raw: unknown): ContestSpec | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  if (!o.poses || typeof o.poses !== "object") return null;
  const poses: Record<string, ContestPose> = {};
  for (const [name, value] of Object.entries(o.poses as Record<string, unknown>).slice(0, 6)) {
    if (!/^[a-z0-9_]{1,16}$/i.test(name)) continue;
    const pose = cleanPose(value);
    if (pose) poses[name] = pose;
  }
  const names = Object.keys(poses);
  if (names.length === 0) return null;
  const cycle = Array.isArray(o.cycle) ? o.cycle.map(String).filter((c) => names.includes(c)).slice(0, 6) : [];
  const fail = cleanPose((o.fail as { pose?: unknown } | undefined)?.pose ?? o.fail) ?? { hip: [0, 24], torso: 88, legL: [88, 0], legR: [88, 0], armL: [150, 0], armR: [150, 0] };
  const props: ContestProp[] = [];
  for (const raw of (Array.isArray(o.props) ? o.props : []).slice(0, 8)) {
    if (!raw || typeof raw !== "object") continue;
    const q = raw as Record<string, unknown>;
    const attach = ANCHORS.includes(q.attach as PropAnchor) ? (q.attach as PropAnchor) : "floor";
    const base = { attach, failDrop: q.failDrop === true, fill: q.fill === true, w2: n(q.w2, 2, 20) };
    if (q.shape === "line") {
      const a = pair(q.a, -700, 700), b = pair(q.b, -700, 700);
      if (a && b) props.push({ shape: "line", a, b, ...base });
    } else if (q.shape === "circle") {
      const x = n(q.x, -700, 700), y = n(q.y, -300, 900), r = n(q.r, 4, 300);
      if (x !== undefined && y !== undefined && r !== undefined) props.push({ shape: "circle", x, y, r, ...base });
    } else if (q.shape === "rect") {
      const x = n(q.x, -700, 700), y = n(q.y, -300, 900), w = n(q.w, 4, 900), h = n(q.h, 4, 900);
      if (x !== undefined && y !== undefined && w !== undefined && h !== undefined) props.push({ shape: "rect", x, y, w, h, ...base });
    }
  }
  return {
    name: String(o.name ?? "contest").slice(0, 40),
    poses,
    cycle,
    tired: typeof o.tired === "string" && names.includes(o.tired) ? o.tired : undefined,
    repS: n(o.repS, 0.6, 4),
    fail: { pose: fail },
    props,
    snap: o.snap === false ? false : true,
  };
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
  activity?: ShowdownActivity;
  custom?: ContestSpec;
}

/** A designed contest from the brief, if there is a usable one. */
function customOf(o: Record<string, unknown>): { activity?: ShowdownActivity; custom?: ContestSpec } {
  if (o.activity !== "custom") return {};
  const custom = parseContest(o.custom);
  return custom ? { activity: "custom", custom } : { activity: "pullup" };
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
    value: { title: String(o.title ?? "Showdown").slice(0, 80), losers, winner, kicker, caption: String(o.caption ?? "").slice(0, 400), activity: o.activity === "plank" ? "plank" : "pullup" as ShowdownActivity, ...customOf(o) },
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
  return { durationS: Math.round((beatS + 6.4) * 10) / 10, fps, losers, winner: brief.winner, beatS, activity: brief.activity ?? "pullup", ...(brief.custom ? { custom: brief.custom } : {}) };
}

export const SHOWDOWN_WRITER_PROMPT = `You write the words for a "Stickman Showdown" short video.

WHAT IT IS: black screen, white stick figures each do the SAME physical challenge side by side. Each has one bold label. They get tired (arms turn red) and drop one by one. The music drops and the camera whips to one last figure nobody saw coming, glowing, still going. No voice, no sentences: the labels are the whole script, so the idea has to land from a few words alone.

HOW TO CHOOSE THE LABELS
- Each label is ONE upper-case word (two at most) that people recognise in themselves: MOTIVATION, EGO, TALENT, LUCK, HYPE, COMFORT, DISCIPLINE, CONSISTENCY, OBSESSION.
- The LOSERS are things most people rely on that run out under pressure, in the order they quit. 1 to 3 of them.
- The WINNER is the quality that lasts when the others are gone. It is the message of the video. It should feel earned, not generic.
- Fit the person: use what you know about them (niche, audience, what they post about) so the video is about THEIR topic when it makes sense. If they asked for a theme, the labels must carry it.
- Never copy another creator's exact sequence of labels; make a fresh idea.

Reply with JSON only:
{"title": "...", "losers": ["MOTIVATION","EGO","DISCIPLINE"], "winner": "OBSESSION", "kicker": 1, "caption": "post text, one or two short lines, no hashtags unless asked"}
THE CHALLENGE ("activity"). It is unlimited: pick, or INVENT, whatever physical challenge best carries the idea, and DESIGN it yourself. Use "custom" and describe it as poses (below). Any exercise, sport, chore or struggle works: squats with a barbell, push-ups, sit-ups, running on a treadmill, carrying a heavy box, pushing a car, a wall sit, jumping rope, a handstand, holding a heavy bucket out to the side, climbing a ladder. Match it to the meaning (a long hold for patience, a heavy lift for pressure, running for chasing, carrying for burdens). EVERY video should use a different challenge from the last one you made: if they ask for something different, new, another style, or "not that again", invent a new one. Only fall back to "pullup" or "plank" (which need no design) when nothing else fits.

HOW TO DESIGN A "custom" CHALLENGE. Add "activity":"custom" and a "custom" object. The figure is seen from the SIDE, facing RIGHT. All numbers are pixels or degrees. x is forward (right), y is UP from the floor.
- "poses": 2 to 4 named poses (names: lower-case letters, digits or _). Each pose: "hip":[x,y] (the hip's position; y = its height above the floor: standing straight is about 200), "torso":degrees from straight up (+ = leaning forward), "head":degrees relative to the torso, "arm":[a,b] and "leg":[a,b] (or "armL"/"armR"/"legL"/"legR" to make them differ). For a limb [a,b]: a = angle of the upper segment measured from straight DOWN (0 = hanging, 90 = pointing straight forward, 180 = straight up, -90 = straight back); b = how much the lower segment bends relative to the upper one (arm: + folds the forearm forward and up; leg: a NEGATIVE knee bends the shin back, e.g. [80,-85] is a seated squat thigh). Segments are about 88 px (arms) and 100 px (legs); the torso is 118 px.
- PLANTING: to fix hands or feet on the floor (push-ups, planks, sit-ups, anything where they must not slide) add "pin":{"handL":[x,0],"handR":[x,0],"footL":[x,0],"footR":[x,0]}. A pinned limb ignores its angles and bends by itself to reach the point ("bend":[arms,legs], each 1 forward or -1 backward, default [-1,1]). Unpinned figures are put on the floor automatically; set "snap":false only for jumps.
- "cycle": the poses in the order the figure loops through them (a single name = a held position, such as a wall sit or a plank). "repS": seconds per repetition when fresh (running 0.9, a squat 2). "tired": the pose it sags toward as it gets tired (the lowest, hardest or most collapsed one).
- "fail": {"pose": ...} what it looks like after giving up (usually lying down or sitting). Lying on the back: hip [0,24], torso -88, leg [88,0], arm [-100,0].
- "props": up to 8 things it uses, in the same x/y, each {"shape":"line"|"rect"|"circle", ...}. line: "a":[x,y],"b":[x,y]. rect: "x","y" (centre),"w","h". circle: "x","y","r". Optional "fill":true, "w2":line thickness, "attach": "floor" (default) or "neck","hip","head","handL","handR","footL","footR" (the prop then moves with that part, coordinates relative to it), and "failDrop":true so it falls to the floor when the figure gives up. Draw the floor details a challenge needs (a treadmill belt, a ramp, a box, a wall, a ladder).
Make the motion read at a glance: big, clear differences between the poses of the cycle. Three worked examples, to copy the conventions from (design your own, do not reuse them unless they truly fit):
barbell squat: {"name":"barbell squat","poses":{"up":{"hip":[0,200],"torso":0,"head":0,"arm":[40,120],"leg":[0,0]},"down":{"hip":[-70,118],"torso":35,"head":-10,"arm":[40,120],"leg":[80,-85]}},"cycle":["up","down"],"tired":"down","repS":2,"fail":{"pose":{"hip":[0,24],"torso":-88,"head":0,"arm":[-100,0],"leg":[88,0]}},"props":[{"shape":"circle","x":0,"y":8,"r":42,"attach":"neck","failDrop":true,"w2":10}]}
push-up: {"name":"push-up","poses":{"up":{"hip":[0,115],"torso":55,"head":-10,"pin":{"handL":[90,0],"handR":[90,0],"footL":[-164,0],"footR":[-164,0]}},"down":{"hip":[32,42],"torso":78,"head":-10,"pin":{"handL":[90,0],"handR":[90,0],"footL":[-164,0],"footR":[-164,0]}}},"cycle":["up","down"],"tired":"down","repS":1.6,"fail":{"pose":{"hip":[0,22],"torso":88,"head":0,"arm":[120,0],"leg":[-88,0]}}}
treadmill run: {"name":"treadmill run","poses":{"a":{"hip":[0,185],"torso":14,"armL":[-50,70],"armR":[60,80],"legL":[55,-20],"legR":[-35,-90]},"mid":{"hip":[0,196],"torso":14,"arm":[10,80],"leg":[0,-60]},"c":{"hip":[0,185],"torso":14,"armL":[60,80],"armR":[-50,70],"legL":[-35,-90],"legR":[55,-20]},"slog":{"hip":[0,168],"torso":26,"arm":[20,50],"leg":[25,-35]}},"cycle":["a","mid","c","mid"],"tired":"slog","repS":0.9,"snap":true,"fail":{"pose":{"hip":[0,22],"torso":-88,"arm":[-100,0],"leg":[88,0]}},"props":[{"shape":"line","a":[-260,-4],"b":[260,-4],"w2":14}]}
Return the JSON as {..., "activity":"custom","custom":{...}}.
"kicker" is the index of the loser that kicks its legs at the end (optional, pull-ups only).`;

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
