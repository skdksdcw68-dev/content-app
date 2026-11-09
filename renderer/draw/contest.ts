/**
 * Any contest, described by the model and drawn here.
 *
 * The writer does not pick from a list of exercises: it designs one as a few
 * POSES of a stick figure (angles of the body and limbs, side view, facing
 * right) plus the PROPS it uses (a barbell, a box, a wall, a rope...). This file
 * turns that description into frames: it moves the figure through the poses,
 * tires it (slower, lower, shaking, red arms), drops it out, and keeps its feet
 * on the floor. Nothing here knows what a "squat" is.
 *
 * Coordinates in a spec: x forward (right), y UP from the floor, in pixels of
 * a 1080 px wide frame. Angles are degrees. A limb angle is measured from
 * straight DOWN, positive toward the front (so 90 = straight forward, 180 =
 * straight up, -90 = straight back). Torso is measured from straight UP,
 * positive = leaning forward. Elbow/knee angles are RELATIVE to the segment
 * above (a knee of -80 bends the shin back 80 degrees).
 */
import type { SKRSContext2D } from "@napi-rs/canvas";

import type { ContestPose, ContestProp, ContestSpec } from "../../supabase/functions/_shared/video/drawn.ts";

type Pt = { x: number; y: number };
export type Joints = Record<"head" | "neck" | "shoulder" | "elbowL" | "elbowR" | "handL" | "handR" | "hip" | "kneeL" | "kneeR" | "footL" | "footR", Pt>;

const TORSO = 118;
const NECK = 50;
const ARM = 88;
const LEG = 100;
const HEAD_R = 34;
const LW = 11;

const rad = (d: number) => (d * Math.PI) / 180;
const dir = (phi: number): Pt => ({ x: Math.sin(rad(phi)), y: Math.cos(rad(phi)) });
const clamp = (v: number, a = 0, b = 1) => Math.max(a, Math.min(b, v));
const smooth = (t: number) => t * t * (3 - 2 * t);
const lerp = (a: number, b: number, k: number) => a + (b - a) * k;

type Pins = Partial<Record<"handL" | "handR" | "footL" | "footR", [number, number]>>;
type Flat = { hx: number; hy: number; torso: number; head: number; aL: [number, number]; aR: [number, number]; lL: [number, number]; lR: [number, number]; pin: Pins; bend: [number, number] };

/** A pose with every field filled in. Arms and legs default to hanging and
 *  standing; one arm or leg given alone is used for both. */
function flat(p: ContestPose): Flat {
  const arm = (p.armL ?? p.armR ?? [0, 0]) as [number, number];
  const armR = (p.armR ?? p.armL ?? [0, 0]) as [number, number];
  const leg = (p.legL ?? p.legR ?? [0, 0]) as [number, number];
  const legR = (p.legR ?? p.legL ?? [0, 0]) as [number, number];
  return {
    hx: p.hip?.[0] ?? 0, hy: p.hip?.[1] ?? 200,
    torso: p.torso ?? 0, head: p.head ?? 0,
    aL: arm, aR: armR, lL: leg, lR: legR,
    pin: p.pin ?? {}, bend: p.bend ?? [-1, 1],
  };
}

function mixFlat(a: Flat, b: Flat, k: number): Flat {
  const m2 = (u: [number, number], v: [number, number]): [number, number] => [lerp(u[0], v[0], k), lerp(u[1], v[1], k)];
  return {
    hx: lerp(a.hx, b.hx, k), hy: lerp(a.hy, b.hy, k), torso: lerp(a.torso, b.torso, k), head: lerp(a.head, b.head, k),
    aL: m2(a.aL, b.aL), aR: m2(a.aR, b.aR), lL: m2(a.lL, b.lL), lR: m2(a.lR, b.lR),
    pin: mixPins(a.pin, b.pin, k), bend: k < 0.5 ? a.bend : b.bend,
  };
}

function mixPins(a: Pins, b: Pins, k: number): Pins {
  const out: Pins = {};
  for (const key of ["handL", "handR", "footL", "footR"] as const) {
    const u = a[key], v = b[key];
    if (u && v) out[key] = [lerp(u[0], v[0], k), lerp(u[1], v[1], k)];
    // Planted in only one of the two poses: planted until halfway, then free.
    else if (u && k < 0.5) out[key] = u;
    else if (v && k >= 0.5) out[key] = v;
  }
  return out;
}

/** Two equal bones from "from" to "to": where the middle joint goes. */
function reach(from: Pt, to: Pt, len: number, bend: number): [Pt, Pt] {
  let dx = to.x - from.x, dy = to.y - from.y;
  let d = Math.hypot(dx, dy) || 0.001;
  const max = len * 2 - 0.5;
  if (d > max) { dx *= max / d; dy *= max / d; d = max; }
  const end = { x: from.x + dx, y: from.y + dy };
  const mx = from.x + dx / 2, my = from.y + dy / 2;
  const h = Math.sqrt(Math.max(0, len * len - (d / 2) ** 2));
  const px = -dy / d, py = dx / d;
  const e1 = { x: mx + px * h, y: my + py * h }, e2 = { x: mx - px * h, y: my - py * h };
  return [(e1.x - mx) * bend >= (e2.x - mx) * bend ? e1 : e2, end];
}

/** Forward kinematics: joints in frame coordinates (y down), the figure's
 *  origin at (x0, floor). Not yet snapped to the floor. */
function fk(f: Flat, x0: number, floor: number): Joints {
  const hip = { x: x0 + f.hx, y: floor - f.hy };
  const up = rad(f.torso);
  const neck = { x: hip.x + Math.sin(up) * TORSO, y: hip.y - Math.cos(up) * TORSO };
  const hd = rad(f.torso + f.head);
  const head = { x: neck.x + Math.sin(hd) * NECK, y: neck.y - Math.cos(hd) * NECK };
  const shoulder = { x: neck.x - Math.sin(up) * 12, y: neck.y + Math.cos(up) * 12 };
  const limb = (from: Pt, a: [number, number], len: number): [Pt, Pt] => {
    const d1 = dir(a[0]);
    const mid = { x: from.x + d1.x * len, y: from.y + d1.y * len };
    const d2 = dir(a[0] + a[1]);
    return [mid, { x: mid.x + d2.x * len, y: mid.y + d2.y * len }];
  };
  const world = (v: [number, number]): Pt => ({ x: x0 + v[0], y: floor - v[1] });
  const [elbowL, handL] = f.pin.handL ? reach(shoulder, world(f.pin.handL), ARM, f.bend[0]) : limb(shoulder, f.aL, ARM);
  const [elbowR, handR] = f.pin.handR ? reach(shoulder, world(f.pin.handR), ARM, f.bend[0]) : limb(shoulder, f.aR, ARM);
  const [kneeL, footL] = f.pin.footL ? reach(hip, world(f.pin.footL), LEG, f.bend[1]) : limb(hip, f.lL, LEG);
  const [kneeR, footR] = f.pin.footR ? reach(hip, world(f.pin.footR), LEG, f.bend[1]) : limb(hip, f.lR, LEG);
  return { head, neck, shoulder, elbowL, elbowR, handL, handR, hip, kneeL, kneeR, footL, footR };
}

function shift(j: Joints, dx: number, dy: number): Joints {
  const o = {} as Joints;
  for (const k of Object.keys(j) as (keyof Joints)[]) o[k] = { x: j[k].x + dx, y: j[k].y + dy };
  return o;
}

/** The figure's lowest touching point is put on the floor, so a pose written a
 *  few pixels off never floats or sinks. */
function snapped(j: Joints, floor: number): Joints {
  const low = Math.max(j.footL.y, j.footR.y, j.handL.y, j.handR.y, j.kneeL.y, j.kneeR.y, j.hip.y, j.head.y + HEAD_R);
  return shift(j, 0, floor - low);
}

const mixC = (a: number[], b: number[], t: number) => a.map((v, i) => Math.round(v + (b[i]! - v) * t));

function stroke(g: SKRSContext2D, a: Pt, b: Pt, color: string) {
  g.strokeStyle = color;
  g.beginPath(); g.moveTo(a.x, a.y); g.lineTo(b.x, b.y); g.stroke();
}

/** The figure, drawn the way the pull-up figure is: white, arms reddening as it tires. */
export function drawFigure(g: SKRSContext2D, j: Joints, s: number, alpha: number) {
  g.lineCap = "round"; g.lineJoin = "round"; g.lineWidth = LW;
  const white = `rgba(255,255,255,${alpha})`;
  const red = (t: number) => { const c = mixC([255, 255, 255], [232, 33, 58], clamp(t)); return `rgba(${c[0]},${c[1]},${c[2]},${alpha})`; };
  stroke(g, j.hip, j.kneeL, white); stroke(g, j.kneeL, j.footL, white);
  stroke(g, j.hip, j.kneeR, white); stroke(g, j.kneeR, j.footR, white);
  stroke(g, j.neck, j.hip, white);
  for (const [e, h] of [[j.elbowL, j.handL], [j.elbowR, j.handR]] as [Pt, Pt][]) {
    stroke(g, j.shoulder, e, red(s * 1.2 - 0.35));
    stroke(g, e, h, red(s * 1.4));
    if (s > 0.25) {
      g.fillStyle = `rgba(232,33,58,${alpha * clamp((s - 0.25) * 2)})`;
      g.beginPath(); g.arc(h.x, h.y, 10, 0, Math.PI * 2); g.fill();
    }
  }
  g.fillStyle = "#000";
  g.beginPath(); g.arc(j.head.x, j.head.y, HEAD_R, 0, Math.PI * 2); g.fill();
  g.strokeStyle = white;
  g.beginPath(); g.arc(j.head.x, j.head.y, HEAD_R, 0, Math.PI * 2); g.stroke();
  g.fillStyle = white;
  for (const ex of [-3, 13]) { g.beginPath(); g.arc(j.head.x + ex, j.head.y - 3, 4.2, 0, Math.PI * 2); g.fill(); }
}

export interface Contest {
  /** Width and height of the tallest/widest pose, in pixels. */
  width: number;
  height: number;
  minX: number;
  maxX: number;
  /** The figure's joints at time `t` while it is still going. */
  going(x0: number, floor: number, t: number, s: number, i: number, fast: boolean): Joints;
  /** And after it has dropped out, `tf` seconds ago. */
  out(x0: number, floor: number, t: number, tf: number, i: number): Joints;
  /** Draws the props. `tf` is null while the figure is still going. */
  props(g: SKRSContext2D, joints: Joints, x0: number, floor: number, alpha: number, tf: number | null, dropJoints: Joints | null): void;
  /** Seconds from dropping out to hitting the floor, for the thud. */
  landS: number;
}

export function makeContest(spec: ContestSpec): Contest {
  const names = Object.keys(spec.poses);
  const poses = new Map(names.map((n) => [n, flat(spec.poses[n]!)]));
  const cycle = (spec.cycle && spec.cycle.length > 0 ? spec.cycle : [names[0]!]).filter((n) => poses.has(n));
  const tiredName = spec.tired && poses.has(spec.tired) ? spec.tired : cycle[cycle.length - 1]!;
  const tiredFlat = poses.get(tiredName)!;
  const failFlat = flat(spec.fail.pose);
  const repS = spec.repS ?? 1.5;
  const planted = (f: Flat) => Object.keys(f.pin).length > 0;
  const snap = spec.snap !== false;
  const landS = 0.34;

  // Size of the whole routine, so the stage can be framed.
  let minX = 1e9, maxX = -1e9, maxY = 0;
  for (const n of names) {
    const pf = poses.get(n)!;
    const j = snap && !planted(pf) ? snapped(fk(pf, 0, 0), 0) : fk(pf, 0, 0);
    for (const k of Object.keys(j) as (keyof Joints)[]) {
      minX = Math.min(minX, j[k].x - (k === "head" ? HEAD_R : 0)); maxX = Math.max(maxX, j[k].x + (k === "head" ? HEAD_R : 0));
      maxY = Math.max(maxY, -j[k].y + (k === "head" ? HEAD_R : 0));
    }
  }
  for (const p of spec.props ?? []) {
    for (const pt of propPoints(p)) { minX = Math.min(minX, pt.x); maxX = Math.max(maxX, pt.x); maxY = Math.max(maxY, pt.y); }
  }
  const width = Math.max(240, maxX - minX);
  const height = Math.max(300, maxY);

  const build = (f: Flat, x0: number, floor: number, doSnap: boolean): Joints => {
    const j = fk(f, x0, floor);
    return doSnap && !planted(f) ? snapped(j, floor) : j;
  };

  return {
    width, height, minX, maxX, landS,
    going(x0, floor, t, s, i, fast) {
      // Which two poses of the cycle we are between, and how far.
      const period = Math.max(0.35, repS * (1 + 0.9 * s) * (fast ? 0.8 : 1));
      let f: Flat;
      if (cycle.length === 1) {
        f = poses.get(cycle[0]!)!;
      } else {
        const u = (t / period + i * 0.31) % 1;
        const seg = u * cycle.length;
        const a = Math.floor(seg) % cycle.length;
        const b = (a + 1) % cycle.length;
        f = mixFlat(poses.get(cycle[a]!)!, poses.get(cycle[b]!)!, smooth(clamp(seg - Math.floor(seg))));
      }
      // Tiring pulls the figure toward its hardest pose, and it starts to shake.
      f = mixFlat(f, tiredFlat, clamp(0.6 * Math.pow(s, 1.3)));
      const trem = s > 0.3 ? (s - 0.3) * 9 : 0;
      const jx = Math.sin(t * 47 + i * 5) * trem;
      const jy = Math.cos(t * 61 + i * 2) * trem * 0.8;
      f = { ...f, hx: f.hx + jx, hy: f.hy + jy, torso: f.torso + Math.sin(t * 29 + i) * trem * 0.5 };
      return build(f, x0, floor, snap);
    },
    out(x0, floor, t, tf, i) {
      const from = mixFlat(poses.get(cycle[0]!)!, tiredFlat, 1);
      const k = smooth(clamp(tf / landS));
      const breathe = Math.sin(t * 2.2 + i) * 2;
      const to = { ...failFlat, hy: failFlat.hy + breathe };
      return build(mixFlat(from, to, k), x0, floor, true);
    },
    props(g, j, x0, floor, alpha, tf, dropJoints) {
      for (const p of spec.props ?? []) {
        const attach = p.attach ?? "floor";
        let ox = x0, oy = floor;
        const anchor = (jj: Joints): Pt | null => (attach === "floor" ? { x: x0, y: floor } : (jj as unknown as Record<string, Pt>)[attach] ?? null);
        const live = anchor(j);
        if (!live) continue;
        ox = live.x; oy = live.y;
        if (tf !== null && p.failDrop && dropJoints) {
          const at = anchor(dropJoints) ?? live;
          const k = smooth(clamp(tf / landS));
          ox = at.x; // keeps its x
          oy = lerp(at.y, floor, k);
        } else if (tf !== null && p.failDrop) {
          oy = floor;
        }
        drawProp(g, p, ox, oy, alpha, attach === "floor");
      }
    },
  };
}

function propPoints(p: ContestProp): Pt[] {
  if (p.shape === "line") return [{ x: p.a![0], y: p.a![1] }, { x: p.b![0], y: p.b![1] }];
  if (p.shape === "circle") return [{ x: p.x! - p.r!, y: p.y! + p.r! }, { x: p.x! + p.r!, y: p.y! - p.r! }];
  return [{ x: p.x! - p.w! / 2, y: p.y! + p.h! / 2 }, { x: p.x! + p.w! / 2, y: p.y! - p.h! / 2 }];
}

/** A prop in the figure's local coordinates (x forward, y up) at the anchor. */
function drawProp(g: SKRSContext2D, p: ContestProp, ox: number, oy: number, alpha: number, onFloor: boolean) {
  g.lineCap = "round"; g.lineJoin = "round";
  g.lineWidth = p.w2 ?? 8;
  g.strokeStyle = `rgba(255,255,255,${alpha * (onFloor ? 0.9 : 1)})`;
  g.fillStyle = `rgba(255,255,255,${alpha})`;
  if (p.shape === "line") {
    g.beginPath(); g.moveTo(ox + p.a![0], oy - p.a![1]); g.lineTo(ox + p.b![0], oy - p.b![1]); g.stroke();
  } else if (p.shape === "circle") {
    g.beginPath(); g.arc(ox + p.x!, oy - p.y!, p.r!, 0, Math.PI * 2);
    if (p.fill) g.fill(); else g.stroke();
  } else {
    const x = ox + p.x! - p.w! / 2, y = oy - p.y! - p.h! / 2;
    if (p.fill) g.fillRect(x, y, p.w!, p.h!); else g.strokeRect(x, y, p.w!, p.h!);
  }
}
