/**
 * Stickman Showdown, drawn in code: white stick figures with a bold label each
 * do pull-ups, tire (arms turn red), drop one by one, and a hidden last one
 * is revealed on the music's drop. No pictures or video models are used, so a
 * clip costs the render time and nothing else.
 *
 * The plan (`ShowdownPlan`) is all the writer has to produce; every pose, the
 * camera and the sound effects follow from it. Ported from the preview
 * script that made stickman-v5.mp4 (8 Nov 2026).
 */
import type { SKRSContext2D } from "@napi-rs/canvas";

import type { ShowdownPlan } from "../../supabase/functions/_shared/video/drawn.ts";
export type { ShowdownPlan };

export interface Showdown {
  width: number;
  height: number;
  /** Seconds each loser hits the ground, for the thud sound. */
  landings: number[];
  /** Draws the frame at time `t` (seconds). Call with increasing `t`. */
  draw(g: SKRSContext2D, t: number): void;
}

type Pt = { x: number; y: number };
type Rgb = [number, number, number];
type Pose = Record<"head" | "neck" | "shL" | "shR" | "handL" | "handR" | "hip" | "kneeL" | "kneeR" | "footL" | "footR", Pt>;

const RED: Rgb = [232, 33, 58];
const WHITE: Rgb = [255, 255, 255];
const mix = (a: Rgb, b: Rgb, t: number): Rgb => [0, 1, 2].map((i) => Math.round(a[i]! + (b[i]! - a[i]!) * t)) as Rgb;
const rgb = (c: Rgb, a = 1) => `rgba(${c[0]},${c[1]},${c[2]},${a})`;
const clamp = (v: number, a = 0, b = 1) => Math.max(a, Math.min(b, v));
const ease = (t: number) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);
const easeCam = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const seg = (t: number, a: number, b: number) => clamp((t - a) / (b - a));
const P = (x: number, y: number): Pt => ({ x, y });
const lerpP = (a: Pt, b: Pt, k: number) => P(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k);

const W = 1080;
const H = 1920;
const BAR = 700;
const GROUND = BAR + 880;
const GRAV = 3200;
const LW = 11;
const HANG_HIP = BAR + 300;
const SIT_HIP = GROUND - 30;
const T_LAND = Math.sqrt((2 * (SIT_HIP - HANG_HIP)) / GRAV);
const SPACING = 330;

/** Two-bone arm: the elbow bends away from the body. */
function elbow(S: Pt, Hd: Pt, out: number, a = 88): Pt {
  let dx = Hd.x - S.x;
  let dy = Hd.y - S.y;
  let d = Math.hypot(dx, dy);
  const maxD = a * 2 - 0.5;
  if (d > maxD) { dx *= maxD / d; dy *= maxD / d; d = maxD; }
  const m = P(S.x + dx / 2, S.y + dy / 2);
  const h = Math.sqrt(Math.max(0, a * a - (d / 2) ** 2));
  const px = -dy / d;
  const py = dx / d;
  const e1 = P(m.x + px * h, m.y + py * h);
  const e2 = P(m.x - px * h, m.y - py * h);
  return (e1.x - S.x) * out > (e2.x - S.x) * out ? e1 : e2;
}

function rot(p: Pt, c: Pt, th: number): Pt {
  const s = Math.sin(th);
  const co = Math.cos(th);
  const x = p.x - c.x;
  const y = p.y - c.y;
  return P(c.x + x * co - y * s, c.y + x * s + y * co);
}

interface Fig { label: string; x: number; dropS: number | null; tired: [number, number]; kick: boolean; phase: number }

function hangPose(f: Fig, t: number, s: number, i: number, lift: number): Pose {
  const x = f.x;
  const kick = f.kick && s > 0.45 ? Math.sin(t * 13) * 44 * seg(s, 0.45, 0.7) : 0;
  const p: Pose = {
    handL: P(x - 62, BAR), handR: P(x + 62, BAR),
    head: P(x, BAR + 72 - lift), neck: P(x, BAR + 108 - lift),
    shL: P(x - 30, BAR + 128 - lift), shR: P(x + 30, BAR + 128 - lift),
    hip: P(x, HANG_HIP - lift),
    kneeL: P(x - 18 + kick, HANG_HIP + 100 - lift), kneeR: P(x + 18 - kick * 0.7, HANG_HIP + 100 - lift),
    footL: P(x - 10 + kick * 1.6, HANG_HIP + 198 - lift), footR: P(x + 10 - kick * 1.2, HANG_HIP + 198 - lift),
  };
  const th = (0.022 + 0.05 * s) * Math.sin(t * 1.7 + i * 1.3);
  const A = s > 0.55 ? (s - 0.55) * 16 : 0;
  const jx = Math.sin(t * 53 + i * 7) * A;
  const jy = Math.cos(t * 71 + i * 3) * A * 0.5;
  const pivot = P(x, BAR);
  for (const k of Object.keys(p) as (keyof Pose)[]) {
    if (k === "handL" || k === "handR") continue;
    const r = rot(p[k], pivot, th);
    p[k] = P(r.x + jx, r.y + jy);
  }
  return p;
}

function fallPose(f: Fig, tf: number): Pose {
  const x = f.x;
  const dy = 0.5 * GRAV * tf * tf;
  const spin = tf * 0.5;
  const base: Pose = {
    head: P(x, BAR + 72 + dy), neck: P(x, BAR + 108 + dy),
    shL: P(x - 30, BAR + 128 + dy), shR: P(x + 30, BAR + 128 + dy),
    handL: P(x - 70, BAR - 10 + dy), handR: P(x + 70, BAR - 10 + dy),
    hip: P(x, HANG_HIP + dy),
    kneeL: P(x - 24, HANG_HIP + 98 + dy), kneeR: P(x + 24, HANG_HIP + 98 + dy),
    footL: P(x - 30, HANG_HIP + 196 + dy), footR: P(x + 30, HANG_HIP + 196 + dy),
  };
  const c = base.hip;
  for (const k of Object.keys(base) as (keyof Pose)[]) base[k] = rot(base[k], c, spin * 0.25);
  return base;
}

function sitPose(f: Fig, t: number, i: number): Pose {
  const x = f.x;
  const breathe = Math.sin(t * 2.4 + i) * 4;
  return {
    head: P(x + 4, GROUND - 236 + breathe), neck: P(x + 2, GROUND - 200 + breathe),
    shL: P(x - 24, GROUND - 182 + breathe), shR: P(x + 24, GROUND - 182 + breathe),
    hip: P(x, SIT_HIP),
    kneeL: P(x - 34, GROUND - 112), kneeR: P(x + 34, GROUND - 112),
    footL: P(x - 54, GROUND), footR: P(x + 54, GROUND),
    handL: P(x - 34, GROUND - 120), handR: P(x + 34, GROUND - 120),
  };
}

function line(g: SKRSContext2D, a: Pt, b: Pt, color: string) {
  g.strokeStyle = color;
  g.beginPath(); g.moveTo(a.x, a.y); g.lineTo(b.x, b.y); g.stroke();
}

function figure(g: SKRSContext2D, p: Pose, s: number, alpha: number, armOut: [number, number] = [-1, 1]) {
  g.lineCap = "round"; g.lineJoin = "round"; g.lineWidth = LW;
  const white = rgb(WHITE, alpha);
  line(g, p.hip, p.kneeL, white); line(g, p.kneeL, p.footL, white);
  line(g, p.hip, p.kneeR, white); line(g, p.kneeR, p.footR, white);
  line(g, p.neck, p.hip, white);
  // Arms: the forearm reddens first, then the upper arm.
  for (const [S, Hd, out] of [[p.shL, p.handL, armOut[0]], [p.shR, p.handR, armOut[1]]] as [Pt, Pt, number][]) {
    const E = elbow(S, Hd, out);
    line(g, S, E, rgb(mix(WHITE, RED, clamp(s * 1.2 - 0.35)), alpha));
    line(g, E, Hd, rgb(mix(WHITE, RED, clamp(s * 1.4)), alpha));
    if (s > 0.25) {
      g.fillStyle = rgb(RED, alpha * clamp((s - 0.25) * 2));
      g.beginPath(); g.arc(Hd.x, Hd.y, 10, 0, Math.PI * 2); g.fill();
    }
  }
  line(g, p.shL, p.shR, white);
  // Head: filled black so the arms behind it vanish, then the ring and eyes.
  g.fillStyle = "#000";
  g.beginPath(); g.arc(p.head.x, p.head.y, 34, 0, Math.PI * 2); g.fill();
  g.strokeStyle = white;
  g.beginPath(); g.arc(p.head.x, p.head.y, 34, 0, Math.PI * 2); g.stroke();
  g.fillStyle = white;
  for (const ex of [-11, 11]) { g.beginPath(); g.arc(p.head.x + ex, p.head.y - 3, 4.2, 0, Math.PI * 2); g.fill(); }
}

// ---- the plank contest: forearm plank on a floor line, side view, facing left.
const PG = 1180; // the floor of the plank stage
const PLANK_LAND = 0.32;

function plankPose(f: Fig, t: number, s: number, i: number): Pose {
  const x = f.x;
  const sag = 64 * Math.pow(s, 1.5);
  const trem = s > 0.3 ? (s - 0.3) * 10 : 0;
  const jx = Math.sin(t * 47 + i * 5) * trem;
  const jy = Math.cos(t * 61 + i * 2) * trem * 0.8;
  const base: Pose = {
    handL: P(x - 12, PG), handR: P(x - 12, PG),
    shL: P(x - 104, PG - 90), shR: P(x - 96, PG - 90),
    neck: P(x - 122, PG - 98), head: P(x - 168, PG - 116),
    hip: P(x + 70, PG - 92 + sag),
    kneeL: P(x + 168, PG - 52 + sag * 0.4), kneeR: P(x + 176, PG - 50 + sag * 0.4),
    footL: P(x + 266, PG - 6), footR: P(x + 274, PG - 5),
  };
  for (const k of Object.keys(base) as (keyof Pose)[]) {
    if (k === "handL" || k === "handR") continue;
    base[k] = P(base[k].x + jx, base[k].y + jy);
  }
  return base;
}

function plankLie(f: Fig, t: number, i: number): Pose {
  const x = f.x;
  const b = Math.sin(t * 2.2 + i) * 2;
  return {
    handL: P(x - 110, PG - 4), handR: P(x - 100, PG - 4),
    shL: P(x - 130, PG - 26 + b), shR: P(x - 120, PG - 26 + b),
    neck: P(x - 150, PG - 28 + b), head: P(x - 196, PG - 36 + b),
    hip: P(x + 60, PG - 20),
    kneeL: P(x + 160, PG - 14), kneeR: P(x + 168, PG - 12),
    footL: P(x + 262, PG - 8), footR: P(x + 270, PG - 6),
  };
}

function label(g: SKRSContext2D, text: string, x: number, y: number, alpha: number, glow: number) {
  g.font = "bold 58px Oswald";
  g.textBaseline = "alphabetic";
  const track = 4;
  const widths = [...text].map((ch) => g.measureText(ch).width);
  const total = widths.reduce((a, b) => a + b, 0) + track * (text.length - 1);
  let cx = x - total / 2;
  g.fillStyle = rgb(WHITE, alpha);
  if (glow > 0) { g.shadowColor = rgb(WHITE, 0.9); g.shadowBlur = 40 * glow; }
  [...text].forEach((ch, i) => { g.fillText(ch, cx, y); cx += widths[i]! + track; });
  g.shadowBlur = 0;
}

type CamKey = [number, number, number, number];

/** Camera: before each drop it settles on that figure, after it eases off, and
 *  on the beat it whips to the hidden winner. */
function cameraKeys(plan: ShowdownPlan, xs: number[], winnerX: number): CamKey[] {
  const keys: CamKey[] = [[0, xs[1] ?? xs[0] ?? 0, 1000, 1.0]];
  plan.losers.forEach((l, i) => {
    const x = xs[i]!;
    const settle = Math.max(keys[keys.length - 1]![0] + 0.4, l.dropS - 3.2);
    keys.push([settle, x, 990, 1.22]);
    keys.push([l.dropS - 0.2, x, 1000, 1.26]);
    keys.push([l.dropS + 0.5, x, 1080, 1.1]);
  });
  const beat = Math.max(plan.beatS, keys[keys.length - 1]![0] + 0.4);
  keys.push([beat, winnerX, 950, 1.32]);
  keys.push([plan.durationS - 1.6, winnerX, 930, 1.36]);
  keys.push([plan.durationS, winnerX, 900, 1.56]);
  return keys;
}

function camera(keys: CamKey[], t: number): [number, number, number] {
  for (let i = 0; i < keys.length - 1; i++) {
    const [t0, ...a] = keys[i]!;
    const [t1, ...b] = keys[i + 1]!;
    if (t <= t1) {
      const k = easeCam(seg(t, t0, t1));
      return [a[0]! + (b[0]! - a[0]!) * k, a[1]! + (b[1]! - a[1]!) * k, a[2]! + (b[2]! - a[2]!) * k];
    }
  }
  const last = keys[keys.length - 1]!;
  return [last[1], last[2], last[3]];
}

export function showdown(plan: ShowdownPlan): Showdown {
  const fps = plan.fps;
  const plank = plan.activity === "plank";
  const losers = plan.losers.slice(0, 3);
  const xs = losers.map((_, i) => i * (plank ? 560 : SPACING));
  const winnerX = (xs[xs.length - 1] ?? 0) + (plank ? 760 : 640);
  const figs: Fig[] = losers.map((l, i) => ({
    label: l.label, x: xs[i]!, dropS: l.dropS,
    tired: l.tiredS ?? [0.3 + i * 1.1, l.dropS], kick: Boolean(l.kick), phase: (i * 0.31) % 1,
  }));
  // Hidden off screen to the right until the drop: the viewer never knows
  // there is one more, so the reveal lands on them.
  figs.push({ label: plan.winner, x: winnerX, dropS: null, tired: [2, 60], kick: false, phase: 0.18 });
  const BEAT = plan.beatS;
  let keys = cameraKeys({ ...plan, losers }, xs, winnerX);
  // The plank is wide and low: come in close and sit the camera on the floor so
  // the frame is filled by the figure, not by black.
  if (plank) keys = keys.map(([t, x, y, z]): CamKey => [t, x + 95, 1080 + (y - 1000) * 0.3, z * 1.45]);
  // Each figure's pull-up clock: a rep takes 0.5 s fresh, about 1.1 s at the end.
  const phases = figs.map((f) => f.phase);
  let lastT = -1;

  return {
    width: W,
    height: H,
    landings: losers.map((l) => l.dropS + (plank ? PLANK_LAND : T_LAND)),
    draw(g, t) {
      const dt = lastT < 0 ? 0 : Math.max(0, t - lastT);
      lastT = t;
      g.setTransform(1, 0, 0, 1, 0, 0);
      g.fillStyle = "#000"; g.fillRect(0, 0, W, H);
      const [cx, cy, z] = camera(keys, t);
      g.setTransform(z, 0, 0, z, W / 2 - cx * z, H / 2 - cy * z);

      figs.forEach((f, i) => {
        const drop = f.dropS;
        const gone = drop != null && t >= drop;
        if (plank) {
          g.lineCap = "round"; g.lineWidth = 6; g.strokeStyle = rgb(WHITE, 0.55);
          g.beginPath(); g.moveTo(f.x - 250, PG + 8); g.lineTo(f.x + 330, PG + 8); g.stroke();
          const fadeP = gone ? 1 - 0.6 * seg(t, drop!, drop! + 0.8) : 1;
          const winnerP = drop == null;
          const glowP = winnerP ? seg(t, BEAT - 0.05, BEAT + 0.25) : 0;
          label(g, f.label, f.x + 40, PG - 215, fadeP, glowP);
          let sP = Math.pow(seg(t, f.tired[0], f.tired[1]), 1.4);
          if (winnerP) sP = 0.5 * seg(t, 2, 12) * (1 - 0.85 * seg(t, BEAT - 0.1, BEAT + 0.3));
          if (!gone) {
            const aura = winnerP ? seg(t, BEAT - 0.05, BEAT + 0.4) : 0;
            if (aura > 0) { g.shadowColor = rgb(WHITE, 0.85); g.shadowBlur = 34 * aura; }
            figure(g, plankPose(f, t, sP, i), sP, 1, [-1, -1]);
            g.shadowBlur = 0;
          } else {
            const tf = t - drop!;
            const k = ease(seg(tf, 0, PLANK_LAND));
            const a = plankPose(f, t, 1, i);
            const b = plankLie(f, t, i);
            const q = {} as Pose;
            for (const key of Object.keys(b) as (keyof Pose)[]) q[key] = lerpP(a[key], b[key], k);
            figure(g, q, 0.9 - 0.4 * seg(tf, 1, 4), 1, [-1, -1]);
          }
          return;
        }
        g.lineCap = "round"; g.lineWidth = 10; g.strokeStyle = rgb(WHITE, 1);
        g.beginPath(); g.moveTo(f.x - 112, BAR); g.lineTo(f.x + 112, BAR); g.stroke();
        const fade = gone ? 1 - 0.6 * seg(t, drop!, drop! + 0.8) : 1;
        const isWinner = drop == null;
        const glow = isWinner ? seg(t, BEAT - 0.05, BEAT + 0.25) : 0;
        label(g, f.label, f.x, BAR - 120, fade, glow);

        // Fatigue 0..1. The winner tires a little, then gets a second wind.
        let s = Math.pow(seg(t, f.tired[0], f.tired[1]), 1.4);
        if (isWinner) s = 0.45 * seg(t, 2, 12) * (1 - 0.8 * seg(t, BEAT - 0.1, BEAT + 0.3));
        const period = isWinner && t >= BEAT ? 0.42 : 0.5 + 0.6 * s;
        const amp = 122 * (1 - 0.8 * Math.pow(s, 1.6));
        phases[i] = phases[i]! + dt / period;
        const ph = phases[i]! % 1;
        const lift = amp * Math.pow(Math.max(0, Math.sin(Math.PI * Math.min(1, ph * 1.1))), 0.75);
        if (!gone) {
          const aura = isWinner ? seg(t, BEAT - 0.05, BEAT + 0.4) : 0;
          if (aura > 0) { g.shadowColor = rgb(WHITE, 0.85); g.shadowBlur = 34 * aura; }
          figure(g, hangPose(f, t, s, i, lift), s, 1);
          g.shadowBlur = 0;
        } else {
          const tf = t - drop!;
          if (tf < T_LAND) figure(g, fallPose(f, tf), 1, 1);
          else {
            const k = ease(seg(tf, T_LAND, T_LAND + 0.22));
            const a = fallPose(f, T_LAND);
            const b = sitPose(f, t, i);
            const p = {} as Pose;
            for (const key of Object.keys(b) as (keyof Pose)[]) p[key] = lerpP(a[key], b[key], k);
            figure(g, p, 0.9 - 0.4 * seg(tf, 1, 4), 1);
          }
        }
      });
    },
  };
}
