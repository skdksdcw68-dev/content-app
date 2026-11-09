/**
 * Glow Explainer, drawn in code. 16:9, black, every scene a full-frame little
 * world in white line and glow (a hill and a flag, a night town, a globe, a
 * staircase, a phone feed, a machine of gears...), with drifting dust, light
 * blooms, and a camera that never stops. The plan (drawn.ts `GlowPlan`) says
 * which scene kind each part of the narration gets; labels and numbers appear
 * on the word the voice says, so any voice re-times the whole video.
 * Modelled on the viral references studied on 8 Nov 2026.
 */
import { createCanvas } from "@napi-rs/canvas";
import type { SKRSContext2D } from "@napi-rs/canvas";
import { cueIndex, cueTime, sceneStarts } from "../../supabase/functions/_shared/video/drawn.ts";
import type { CurveShape, GlowPlan, GlowScene, IconName, SceneKind } from "../../supabase/functions/_shared/video/drawn.ts";
import type { WordTiming } from "../../supabase/functions/_shared/video/types.ts";

export interface Glow {
  width: number;
  height: number;
  durationS: number;
  draw(g: SKRSContext2D, t: number): void;
}

type G = SKRSContext2D;
const W = 1920;
const H = 1080;
const GY = 820;
const clamp = (v: number, a = 0, b = 1) => Math.max(a, Math.min(b, v));
const seg = (t: number, a: number, b: number) => clamp((t - a) / (b - a));
const outC = (t: number) => 1 - Math.pow(1 - t, 3);
const outB = (t: number) => { const c = 1.7; return 1 + (c + 1) * Math.pow(t - 1, 3) + c * Math.pow(t - 1, 2); };
const inOut = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const lerp = (a: number, b: number, k: number) => a + (b - a) * k;
const white = (a: number) => `rgba(255,255,255,${a})`;
const fmt = (n: number) => Math.round(n).toLocaleString("en-US");
const glow = (g: G, b = 22, a = 0.75) => { g.shadowColor = white(a); g.shadowBlur = b; };
const noGlow = (g: G) => { g.shadowBlur = 0; };
const rr = (g: G, x: number, y: number, w: number, h: number, r: number) => { g.beginPath(); g.roundRect(x, y, w, h, r); };

// ------------------------------------------------------------------- text

function text(g: G, s: string, x: number, y: number, size: number, weight = "Bold", a = 1, align: "center" | "left" = "center", track = 0): number {
  g.font = `${size}px "Poppins ${weight}"`;
  g.textAlign = "left"; g.textBaseline = "middle"; g.fillStyle = white(a);
  const chars = [...s];
  const ws = chars.map((c) => g.measureText(c).width);
  const total = ws.reduce((p, c) => p + c, 0) + track * Math.max(0, chars.length - 1);
  let cx = align === "center" ? x - total / 2 : x;
  chars.forEach((c, i) => { g.fillText(c, cx, y); cx += ws[i]! + track; });
  return total;
}

/** A small white pill with black words, like the references' labels. */
function pill(g: G, s: string, x: number, y: number, k: number, size = 30) {
  if (k <= 0) return;
  g.save(); g.translate(x, y); g.scale(0.85 + 0.15 * clamp(k, 0, 1.1), 0.85 + 0.15 * clamp(k, 0, 1.1)); g.globalAlpha *= clamp(k);
  g.font = `${size}px "Poppins Bold"`;
  const tr = size * 0.07;
  const ws = [...s].map((c) => g.measureText(c).width);
  const tw = ws.reduce((p, c) => p + c, 0) + tr * (ws.length - 1);
  const w = tw + size * 1.7, h = size * 1.9;
  glow(g, 26, 0.5);
  rr(g, -w / 2, -h / 2, w, h, h / 2); g.fillStyle = white(0.94); g.fill();
  noGlow(g);
  g.fillStyle = "#050505"; g.textBaseline = "middle"; g.textAlign = "left";
  let cx = -tw / 2;
  [...s].forEach((c, i) => { g.fillText(c, cx, 2); cx += ws[i]! + tr; });
  g.restore();
}

// ------------------------------------------------------------- primitives

function bloom(g: G, x: number, y: number, r: number, a: number) {
  if (a <= 0) return;
  const gr = g.createRadialGradient(x, y, 0, x, y, r);
  gr.addColorStop(0, white(0.5 * a)); gr.addColorStop(0.35, white(0.14 * a)); gr.addColorStop(1, white(0));
  g.fillStyle = gr; g.fillRect(x - r, y - r, r * 2, r * 2);
}

interface HeroOpts { bulb?: number; dim?: boolean; bob?: number }

/** The recurring character: a plain white silhouette, as in the references. */
function hero(g: G, x: number, y: number, s: number, a = 1, o: HeroOpts = {}) {
  g.save(); g.globalAlpha *= a;
  y += (o.bob ?? 0) * s;
  if (!o.dim) glow(g, 26, 0.75);
  g.fillStyle = o.dim ? white(0.3) : white(1); g.strokeStyle = g.fillStyle as string;
  g.beginPath(); g.arc(x, y - 100 * s, 25 * s, 0, 7); g.fill();
  g.beginPath(); g.moveTo(x - 38 * s, y); g.lineTo(x - 38 * s, y - 38 * s); g.arc(x, y - 38 * s, 38 * s, Math.PI, 0); g.lineTo(x + 38 * s, y); g.closePath(); g.fill();
  if (o.bulb !== undefined) {
    noGlow(g);
    g.lineWidth = 7 * s; g.lineCap = "round";
    g.beginPath(); g.moveTo(x + 22 * s, y - 70 * s); g.lineTo(x + 52 * s, y - 118 * s); g.stroke();
    bloom(g, x + 60 * s, y - 132 * s, 120 * s, o.bulb);
    glow(g, 24, 0.9);
    g.fillStyle = white(0.6 + 0.4 * o.bulb);
    g.beginPath(); g.arc(x + 60 * s, y - 132 * s, 13 * s, 0, 7); g.fill();
  }
  noGlow(g); g.restore();
}

function house(g: G, x: number, y: number, s: number, a: number) {
  g.save(); g.globalAlpha *= a; g.lineWidth = 4; g.strokeStyle = white(0.85); g.lineJoin = "round"; glow(g, 10, 0.3);
  const w = 190 * s, h = 120 * s;
  g.beginPath(); g.rect(x - w / 2, y - h, w, h); g.moveTo(x - w / 2 - 12 * s, y - h); g.lineTo(x, y - h - 70 * s); g.lineTo(x + w / 2 + 12 * s, y - h); g.stroke();
  g.strokeRect(x - 16 * s, y - 62 * s, 32 * s, 62 * s);
  g.strokeRect(x - w / 2 + 18 * s, y - h + 22 * s, 30 * s, 28 * s);
  g.strokeRect(x + w / 2 - 48 * s, y - h + 22 * s, 30 * s, 28 * s);
  noGlow(g); g.restore();
}

function lamp(g: G, x: number, y: number, s: number, t: number, a: number) {
  g.save(); g.globalAlpha *= a;
  const topY = y - 330 * s;
  g.strokeStyle = white(0.8); g.lineWidth = 4; g.beginPath(); g.moveTo(x, y); g.lineTo(x, topY); g.lineTo(x + 52 * s, topY); g.stroke();
  const flick = 0.85 + 0.15 * Math.sin(t * 2 + x);
  const gr = g.createLinearGradient(x + 50 * s, topY, x + 50 * s, y);
  gr.addColorStop(0, white(0.3 * flick)); gr.addColorStop(1, white(0));
  g.fillStyle = gr; g.beginPath(); g.moveTo(x + 40 * s, topY + 4); g.lineTo(x + 62 * s, topY + 4); g.lineTo(x + 150 * s, y); g.lineTo(x - 50 * s, y); g.closePath(); g.fill();
  g.restore();
}

function flag(g: G, x: number, y: number, h: number, t: number, a: number) {
  g.save(); g.globalAlpha *= a; glow(g, 16, 0.6);
  g.strokeStyle = white(1); g.lineWidth = 6; g.lineCap = "round";
  g.beginPath(); g.moveTo(x, y); g.lineTo(x, y - h); g.stroke();
  g.fillStyle = white(0.95); g.beginPath(); g.moveTo(x, y - h);
  for (let i = 0; i <= 10; i++) g.lineTo(x + i * 9, y - h + Math.sin(t * 4 + i * 0.6) * 4 + i * 0.5);
  for (let i = 10; i >= 0; i--) g.lineTo(x + i * 9, y - h + 62 + Math.sin(t * 4 + i * 0.6) * 4 + i * 0.5);
  g.closePath(); g.fill(); noGlow(g); g.restore();
}

function heart(g: G, x: number, y: number, s: number, a: number, fill = true) {
  g.save(); g.globalAlpha *= a; g.translate(x, y); g.scale(s, s);
  g.beginPath(); g.moveTo(0, 8); g.bezierCurveTo(-18, -6, -10, -18, 0, -8); g.bezierCurveTo(10, -18, 18, -6, 0, 8);
  if (fill) { g.fillStyle = white(0.9); g.fill(); } else { g.lineWidth = 2.5 / s; g.strokeStyle = white(0.9); g.stroke(); }
  g.restore();
}

function gear(g: G, x: number, y: number, r: number, rot: number, a = 1) {
  g.save(); g.globalAlpha *= a; g.translate(x, y); g.rotate(rot); g.strokeStyle = white(0.95); g.lineWidth = 5; g.lineJoin = "round";
  g.beginPath();
  const n = 10;
  for (let i = 0; i < n; i++) {
    const a0 = (i / n) * Math.PI * 2, a1 = a0 + (Math.PI * 2) / n;
    g.lineTo(Math.cos(a0) * r * 0.82, Math.sin(a0) * r * 0.82); g.lineTo(Math.cos(a0 + 0.12) * r, Math.sin(a0 + 0.12) * r);
    g.lineTo(Math.cos(a1 - 0.22) * r, Math.sin(a1 - 0.22) * r); g.lineTo(Math.cos(a1 - 0.1) * r * 0.82, Math.sin(a1 - 0.1) * r * 0.82);
  }
  g.closePath(); g.stroke();
  g.beginPath(); g.arc(0, 0, r * 0.3, 0, 7); g.stroke(); g.restore();
}

function icon(g: G, name: IconName, x: number, y: number, s: number, a: number, t = 0) {
  g.save(); g.globalAlpha *= a; glow(g, 18, 0.6);
  g.fillStyle = white(1); g.strokeStyle = white(1); g.lineWidth = 5 * s; g.lineCap = "round"; g.lineJoin = "round";
  switch (name) {
    case "person": g.beginPath(); g.arc(x, y - 40 * s, 18 * s, 0, 7); g.fill(); g.beginPath(); g.moveTo(x - 28 * s, y + 40 * s); g.lineTo(x - 28 * s, y + 8 * s); g.arc(x, y + 8 * s, 28 * s, Math.PI, 0); g.lineTo(x + 28 * s, y + 40 * s); g.closePath(); g.fill(); break;
    case "phone": rr(g, x - 38 * s, y - 66 * s, 76 * s, 132 * s, 14 * s); g.stroke(); g.beginPath(); g.moveTo(x - 10 * s, y - 54 * s); g.lineTo(x + 10 * s, y - 54 * s); g.stroke(); break;
    case "coin": g.beginPath(); g.arc(x, y, 44 * s, 0, 7); g.stroke(); g.font = `${54 * s}px "Poppins Bold"`; g.textAlign = "center"; g.textBaseline = "middle"; g.fillText("$", x, y + 3 * s); break;
    case "gear": noGlow(g); gear(g, x, y, 46 * s, t * 0.8); break;
    case "globe": g.beginPath(); g.arc(x, y, 44 * s, 0, 7); g.stroke(); g.beginPath(); g.ellipse(x, y, 18 * s, 44 * s, 0, 0, 7); g.stroke(); g.beginPath(); g.moveTo(x - 44 * s, y); g.lineTo(x + 44 * s, y); g.stroke(); break;
    case "rocket": g.beginPath(); g.moveTo(x, y - 56 * s); g.quadraticCurveTo(x + 30 * s, y - 14 * s, x + 18 * s, y + 36 * s); g.lineTo(x - 18 * s, y + 36 * s); g.quadraticCurveTo(x - 30 * s, y - 14 * s, x, y - 56 * s); g.stroke(); g.beginPath(); g.arc(x, y - 6 * s, 8 * s, 0, 7); g.stroke(); break;
    case "bulb": g.beginPath(); g.arc(x, y - 10 * s, 30 * s, Math.PI * 0.8, Math.PI * 0.2); g.lineTo(x + 12 * s, y + 28 * s); g.lineTo(x - 12 * s, y + 28 * s); g.closePath(); g.stroke(); g.beginPath(); g.moveTo(x - 10 * s, y + 42 * s); g.lineTo(x + 10 * s, y + 42 * s); g.stroke(); break;
    case "graph": g.beginPath(); g.moveTo(x - 50 * s, y - 44 * s); g.lineTo(x - 50 * s, y + 44 * s); g.lineTo(x + 50 * s, y + 44 * s); g.stroke(); g.beginPath(); g.moveTo(x - 36 * s, y + 22 * s); g.lineTo(x - 8 * s, y - 4 * s); g.lineTo(x + 14 * s, y + 10 * s); g.lineTo(x + 44 * s, y - 32 * s); g.stroke(); break;
    case "stairs": g.beginPath(); g.moveTo(x - 50 * s, y + 44 * s); g.lineTo(x - 50 * s, y + 14 * s); g.lineTo(x - 18 * s, y + 14 * s); g.lineTo(x - 18 * s, y - 14 * s); g.lineTo(x + 14 * s, y - 14 * s); g.lineTo(x + 14 * s, y - 44 * s); g.lineTo(x + 50 * s, y - 44 * s); g.stroke(); break;
    case "lock": rr(g, x - 32 * s, y - 6 * s, 64 * s, 50 * s, 9 * s); g.stroke(); g.beginPath(); g.arc(x, y - 6 * s, 20 * s, Math.PI, 0); g.stroke(); break;
    case "heart": heart(g, x, y, 3 * s, 1); break;
    case "clock": g.beginPath(); g.arc(x, y, 42 * s, 0, 7); g.stroke(); g.beginPath(); g.moveTo(x, y); g.lineTo(x, y - 26 * s); g.moveTo(x, y); g.lineTo(x + 18 * s, y + 8 * s); g.stroke(); break;
    case "dice": rr(g, x - 38 * s, y - 38 * s, 76 * s, 76 * s, 14 * s); g.stroke(); for (const [dx, dy] of [[-16, -16], [16, 16], [0, 0], [-16, 16], [16, -16]] as const) { g.beginPath(); g.arc(x + dx * s, y + dy * s, 5 * s, 0, 7); g.fill(); } break;
    case "cube": g.beginPath(); g.moveTo(x, y - 46 * s); g.lineTo(x + 40 * s, y - 24 * s); g.lineTo(x + 40 * s, y + 22 * s); g.lineTo(x, y + 44 * s); g.lineTo(x - 40 * s, y + 22 * s); g.lineTo(x - 40 * s, y - 24 * s); g.closePath(); g.moveTo(x - 40 * s, y - 24 * s); g.lineTo(x, y); g.lineTo(x + 40 * s, y - 24 * s); g.moveTo(x, y); g.lineTo(x, y + 44 * s); g.stroke(); break;
  }
  noGlow(g); g.restore();
}

// ------------------------------------------------------------- scene context

interface Ctx {
  g: G;
  t: number;
  /** Scene progress 0..1. */
  p: number;
  /** Seconds since the scene began. */
  lt: number;
  /** Seconds the scene lasts. */
  len: number;
  sc: GlowScene;
  /** Draws pill `i` (if the scene has it) at x,y. */
  label(i: number, x: number, y: number): void;
  /** Counts the scene's number at x,y if it has one. */
  number(x: number, y: number, size?: number): number | null;
  /** 0..1 pop-in of the scene's i-th label. */
  has(i: number): number;
}

type SceneFn = (c: Ctx) => void;

function stars(g: G, t: number, seed: number, a = 1) {
  for (let i = 0; i < 70; i++) {
    const r1 = Math.sin(i * 91.7 + seed) * 43758.5453, r2 = Math.sin(i * 12.9898 + seed * 3) * 24634.6345;
    const x = (r1 - Math.floor(r1)) * W, y = (r2 - Math.floor(r2)) * (GY - 60);
    g.fillStyle = white((0.15 + 0.45 * (0.5 + 0.5 * Math.sin(t * 1.5 + i))) * a);
    g.fillRect(x, y, 2.4, 2.4);
  }
}

function ground(g: G, y: number, a = 1, dashed = true) {
  g.save(); g.globalAlpha *= a; g.strokeStyle = white(0.55); g.lineWidth = 3;
  if (dashed) g.setLineDash([22, 14]);
  g.beginPath(); g.moveTo(-40, y); g.lineTo(W + 40, y); g.stroke(); g.restore();
}

const journey: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  stars(g, t, 3);
  // A long soft hill; the walker follows it.
  const hillY = (x: number) => 800 - 36 * Math.sin(x / 430) - 0.05 * x;
  g.save(); glow(g, 18, 0.7); g.strokeStyle = white(0.95); g.lineWidth = 5; g.beginPath();
  for (let x = -40; x <= W + 40; x += 20) (x === -40 ? g.moveTo(x, hillY(x)) : g.lineTo(x, hillY(x)));
  g.stroke(); noGlow(g);
  g.fillStyle = "rgba(0,0,0,0.55)"; g.lineTo(W + 40, H + 40); g.lineTo(-40, H + 40); g.closePath(); g.fill(); g.restore();
  const k = inOut(clamp(p * 1.05));
  const wx = lerp(260, 1380, k);
  // Footprints: small lights left behind.
  for (let i = 0; i < 18; i++) {
    const fx = lerp(260, wx, i / 18);
    if (fx < wx - 30) { g.fillStyle = white(0.28); g.beginPath(); g.arc(fx, hillY(fx) + 26, 4, 0, 7); g.fill(); }
  }
  flag(g, 1560, hillY(1560), 230, t, outC(seg(p, 0, 0.2)));
  if (sc.goal) text(g, sc.goal, 1610, hillY(1560) - 290, 58, "Bold", outC(seg(p, 0.1, 0.35)));
  hero(g, wx, hillY(wx), 1.25, 1, { bulb: 0.5 + 0.5 * Math.sin(t * 3), bob: -Math.abs(Math.sin(t * 7)) * 6 });
  if (sc.who) text(g, sc.who, wx, hillY(wx) + 60, 22, "SemiBold", 0.6, "center", 8);
  c.number(430, 250, 110);
  c.label(0, 560, 380); c.label(1, 1120, 300); c.label(2, 760, 560); c.label(3, 1400, 170);
};

const night: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  stars(g, t, 7);
  // The moon, with its caption.
  const mx = 1620, my = 190, mk = outC(seg(p, 0, 0.25));
  g.save(); g.globalAlpha *= mk; glow(g, 30, 0.6); g.strokeStyle = white(0.95); g.lineWidth = 5;
  g.beginPath(); g.arc(mx, my, 62, 0, 7); g.stroke(); g.fillStyle = white(0.9); g.beginPath(); g.arc(mx, my, 62, Math.PI * 0.35, Math.PI * 1.35); g.arc(mx + 26, my - 8, 54, Math.PI * 1.3, Math.PI * 0.4, true); g.closePath(); g.fill(); noGlow(g); g.restore();
  if (sc.who) pill(g, sc.who, mx, my + 120, mk);
  const pan = -p * 140;
  g.save(); g.translate(pan, 0);
  ground(g, GY, 1);
  for (let i = -1; i < 6; i++) { house(g, 280 + i * 520, GY, 1.4, 0.95); lamp(g, 520 + i * 520, GY, 1.4, t, 1); }
  g.restore();
  const hx = 620 + p * 120;
  hero(g, hx, GY, 1.7, 1, { bulb: 0.5 + 0.5 * Math.sin(t * 2.4) });
  c.number(1400, 480, 100);
  c.label(0, 470, 300); c.label(1, 1000, 420); c.label(2, 1240, 280); c.label(3, 760, 160);
};

const globe: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  stars(g, t, 11, 0.7);
  const k = inOut(clamp(p * 1.15));
  const R = lerp(2300, 330, k), top = lerp(640, 340, k), cx = W / 2, cy = top + R;
  g.save(); glow(g, 24, 0.7); g.strokeStyle = white(0.95); g.lineWidth = 5; g.beginPath(); g.arc(cx, cy, R, 0, 7); g.stroke(); noGlow(g);
  g.beginPath(); g.arc(cx, cy, R, 0, 7); g.clip();
  g.strokeStyle = white(0.7); g.lineWidth = 3.5;
  for (let i = -2; i <= 2; i++) { g.beginPath(); g.ellipse(cx + Math.sin(t * 0.25) * 0, cy, R * Math.abs(Math.cos((i * Math.PI) / 7 + t * 0.12)) + 1, R, 0, 0, 7); g.stroke(); }
  for (let i = 1; i <= 3; i++) { g.beginPath(); g.ellipse(cx, cy - R * (0.15 * i) + R * 0.1, R * Math.sqrt(Math.max(0.01, 1 - (0.15 * i) ** 2)), R * 0.12, 0, 0, 7); g.stroke(); }
  g.restore();
  hero(g, cx, top + 4, lerp(2.2, 0.55, k), 1, { bulb: 0.6 + 0.4 * Math.sin(t * 2.5) });
  if (sc.goal) text(g, sc.goal, cx, 120, 62, "Bold", outC(seg(p, 0.45, 0.7)));
  if (sc.title) pill(g, sc.title, cx, Math.min(1010, cy + R * 0.72), outC(seg(p, 0.55, 0.8)));
  c.number(cx, 220, 100);
  c.label(0, 330, 300); c.label(1, 1560, 300); c.label(2, 330, 800); c.label(3, 1560, 800);
};

const stairs: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  const up = sc.direction !== "down";
  stars(g, t, 5, 0.6);
  const n = 9, sw = 150, sh = 92, x0 = 520;
  for (let i = 0; i < n; i++) {
    const k = outC(seg(p, i * 0.05, 0.25 + i * 0.05));
    if (k <= 0) continue;
    const idx = up ? i : n - 1 - i;
    const top = 980 - (idx + 1) * sh, x = x0 + i * sw;
    const gr = g.createLinearGradient(x, top, x + sw, 1080); gr.addColorStop(0, white(0.95)); gr.addColorStop(1, white(0.55));
    g.save(); glow(g, 20, 0.4); g.fillStyle = gr; g.fillRect(x, top + (1 - k) * 160, sw + 1, 1080 - top);
    noGlow(g); g.restore();
  }
  const climb = inOut(seg(p, 0.15, 0.95));
  const fi = clamp(climb * (n - 1), 0, n - 1), i0 = Math.floor(fi);
  const idxOf = (i: number) => (up ? i : n - 1 - i);
  const sx = (i: number) => x0 + i * sw + sw / 2, sy = (i: number) => 980 - (idxOf(i) + 1) * sh;
  const f = fi - i0, hx = lerp(sx(i0), sx(Math.min(n - 1, i0 + 1)), f), hy = lerp(sy(i0), sy(Math.min(n - 1, i0 + 1)), f);
  hero(g, up ? hx : hx, hy, 1.2, 1, { bulb: 0.4 + 0.4 * Math.sin(t * 3), bob: -Math.abs(Math.sin(t * 6)) * 5 });
  // A glow at the end of the climb.
  bloom(g, sx(n - 1), sy(n - 1) - 80, 320, seg(p, 0.7, 1));
  ground(g, 980, 0.6);
  c.number(260, 300, 110);
  c.label(0, 330, 560); c.label(1, 1100, 200); c.label(2, 1500, 120); c.label(3, 300, 800);
};

const feed: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  stars(g, t, 13, 0.5);
  const px = 960, py = 540, w = 400, h = 760;
  g.save(); glow(g, 24, 0.5); rr(g, px - w / 2, py - h / 2, w, h, 54); g.lineWidth = 6; g.strokeStyle = white(1); g.stroke(); noGlow(g);
  rr(g, px - 40, py - h / 2 + 18, 80, 12, 6); g.fillStyle = white(0.7); g.fill();
  rr(g, px - w / 2 + 10, py - h / 2 + 50, w - 20, h - 100, 28); g.clip();
  const scroll = (t * 60) % 190;
  const hotAt = sc.number ? clamp((c.lt / c.len - 0.45) * 2) : 0;
  for (let i = -1; i < 5; i++) {
    const cy = py - h / 2 + 110 + i * 190 - scroll;
    rr(g, px - 160, cy, 320, 160, 18); g.lineWidth = 3; g.strokeStyle = white(0.7); g.stroke();
    g.fillStyle = white(0.3); g.fillRect(px - 135, cy + 28, 130, 12); g.fillRect(px - 135, cy + 54, 190, 10);
    heart(g, px - 128, cy + 128, 0.9, 0.9, false);
    text(g, i === 1 && hotAt > 0 ? fmt(2348 * hotAt) : "0", px - 100, cy + 128, 20, "SemiBold", 0.8, "left");
  }
  g.restore();
  if (sc.title) text(g, sc.title, px, py - h / 2 - 50, 34, "Bold", outC(seg(p, 0, 0.15)), "center", 6);
  // Paper planes fly through, nobody catching them.
  for (let i = 0; i < 4; i++) {
    const u = ((t * 0.12 + i * 0.27) % 1), x = lerp(-80, W + 80, u), y = 300 + i * 190 + Math.sin(u * 9 + i) * 70, a = Math.sin(u * Math.PI);
    g.save(); g.globalAlpha *= a * 0.8; g.translate(x, y); g.rotate(Math.sin(u * 9 + i) * 0.4); g.strokeStyle = white(0.9); g.lineWidth = 2.5;
    g.beginPath(); g.moveTo(-22, 8); g.lineTo(26, 0); g.lineTo(-22, -10); g.lineTo(-10, 0); g.closePath(); g.stroke(); g.restore();
  }
  if (hotAt > 0) for (let i = 0; i < 14; i++) { const u = ((t * 0.3 + i * 0.13) % 1); heart(g, 960 + Math.sin(i * 7) * 420, lerp(900, 150, u), 1 + (i % 3) * 0.4, Math.sin(u * Math.PI) * hotAt); }
  c.number(480, 540, 100);
  c.label(0, 1450, 300); c.label(1, 1450, 520); c.label(2, 480, 800); c.label(3, 1450, 780);
};

const grid: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  const n = sc.count ?? 9, cols = Math.min(5, Math.ceil(Math.sqrt(n * 1.5))), rows = Math.ceil(n / cols);
  const cw = 270, ch = 170, gap = 36, tw = cols * cw + (cols - 1) * gap, th = rows * ch + (rows - 1) * gap;
  const hot = Math.min(n - 1, sc.hot ?? Math.floor(n / 2)), hk = inOut(seg(p, 0.4, 0.7));
  for (let i = 0; i < n; i++) {
    const r = Math.floor(i / cols), cc = i % cols, k = outC(seg(p, i * 0.03, 0.2 + i * 0.03));
    if (k <= 0 || i === hot) continue;
    const x = W / 2 - tw / 2 + cc * (cw + gap), y = 560 - th / 2 + r * (ch + gap) + (1 - k) * 40;
    g.save(); g.globalAlpha *= k * lerp(0.9, 0.35, hk);
    rr(g, x, y, cw, ch, 16); g.lineWidth = 3; g.strokeStyle = white(0.8); g.stroke();
    g.fillStyle = white(0.25); g.fillRect(x + 24, y + 30, cw - 48, 70); heart(g, x + 34, y + ch - 28, 0.9, 0.8, false); text(g, String(i % 3), x + 56, y + ch - 28, 20, "SemiBold", 0.7, "left");
    g.restore();
  }
  // The one that worked grows into the middle.
  const r = Math.floor(hot / cols), cc = hot % cols;
  const hx = W / 2 - tw / 2 + cc * (cw + gap) + cw / 2, hy = 560 - th / 2 + r * (ch + gap) + ch / 2;
  const sx = lerp(hx, W / 2, hk), sy = lerp(hy, 540, hk), s = lerp(1, 1.9, hk);
  g.save(); g.translate(sx, sy); g.scale(s, s); g.globalAlpha *= outC(seg(p, 0, 0.2)); glow(g, 36 * hk, 0.8);
  rr(g, -cw / 2, -ch / 2, cw, ch, 16); g.fillStyle = white(0.96); g.fill(); noGlow(g);
  g.fillStyle = "#111"; g.fillRect(-cw / 2 + 24, -ch / 2 + 26, cw - 48, 76); heart(g, -cw / 2 + 36, ch / 2 - 26, 1, 1);
  g.font = '24px "Poppins Bold"'; g.textAlign = "left"; g.textBaseline = "middle"; g.fillStyle = "#050505";
  g.fillText(sc.number ? fmt(lerp(sc.number.from, sc.number.to, hk)) : String(Math.round(hk * 2348)), -cw / 2 + 62, ch / 2 - 26);
  g.restore();
  g.fillStyle = "#000";
  if (hk > 0.5) for (let i = 0; i < 12; i++) { const u = ((t * 0.35 + i * 0.09) % 1); heart(g, W / 2 + Math.sin(i * 5.3) * 640, lerp(960, 120, u), 0.9 + (i % 3) * 0.35, Math.sin(u * Math.PI) * hk); }
  if (sc.title) pill(g, sc.title, W / 2, 1000, outC(seg(p, 0.45, 0.65)));
  c.label(0, 960, 90); c.label(1, 300, 200); c.label(2, 1620, 200); c.label(3, 300, 940);
};

const machine: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  stars(g, t, 17, 0.4);
  const bx = 860, by = 600, bw = 620, bh = 380;
  const bk = outC(seg(p, 0, 0.2));
  g.save(); g.globalAlpha *= bk; glow(g, 22, 0.5); g.strokeStyle = white(1); g.lineWidth = 6; g.lineJoin = "round";
  g.strokeRect(bx - bw / 2, by - bh / 2, bw, bh);
  g.beginPath(); g.moveTo(bx - 130, by - bh / 2); g.lineTo(bx - 90, by - bh / 2 - 90); g.lineTo(bx + 90, by - bh / 2 - 90); g.lineTo(bx + 130, by - bh / 2); g.stroke();
  g.beginPath(); g.moveTo(bx + bw / 2, by + 80); g.lineTo(bx + bw / 2 + 110, by + 130); g.lineTo(bx + bw / 2 + 110, by + 170); g.lineTo(bx + bw / 2, by + 140); g.stroke();
  noGlow(g); g.restore();
  const spin = t * (0.6 + 1.2 * clamp(p * 2));
  gear(g, bx - 150, by + 20, 96, spin, bk); gear(g, bx + 30, by - 70, 62, -spin * 1.55 + 0.2, bk); gear(g, bx + 120, by + 70, 78, spin * 1.2 + 0.1, bk);
  // Things drop in at the top and come out as the parts.
  for (let i = 0; i < 5; i++) {
    const u = (t * 0.45 + i * 0.2) % 1;
    if (u < 0.3) { g.fillStyle = white(0.8 * bk); g.beginPath(); g.arc(bx + Math.sin(i * 3) * 50, by - bh / 2 - 130 + u * 300 * 1.3, 9, 0, 7); g.fill(); }
  }
  const items = sc.items ?? [];
  items.forEach((label, i) => {
    const k = outB(seg(p, 0.3 + i * 0.2, 0.55 + i * 0.2));
    if (k <= 0) return;
    const x = 1560 + (i % 2) * 110 - 40, y = 500 + i * 150 + Math.sin(t * 2 + i) * 8;
    icon(g, sc.icons?.[i] ?? (i % 2 ? "gear" : "cube"), x, y, 1.1 * clamp(k, 0, 1.1), clamp(k), t);
    text(g, label, x, y + 80, 20, "SemiBold", clamp(k) * 0.75, "center", 5);
  });
  if (sc.title) pill(g, sc.title, bx, by - bh / 2 - 190, outC(seg(p, 0.05, 0.3)));
  c.number(300, 380, 100);
  c.label(0, 300, 760); c.label(1, 1560, 220); c.label(2, 300, 200); c.label(3, 860, 1000);
};

const hub: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  stars(g, t, 19, 0.5);
  const cx = 960, cy = 540, items = sc.items ?? [];
  const ck = outB(seg(p, 0, 0.2));
  for (let r = 0; r < 3; r++) { const u = (t * 0.4 + r / 3) % 1; g.strokeStyle = white(0.18 * (1 - u)); g.lineWidth = 3; g.beginPath(); g.arc(cx, cy, 130 + u * 220, 0, 7); g.stroke(); }
  bloom(g, cx, cy, 260, clamp(ck));
  g.save(); glow(g, 30, 0.7); g.strokeStyle = white(1); g.lineWidth = 5; g.beginPath(); g.arc(cx, cy, 118 * clamp(ck, 0, 1.1), 0, 7); g.stroke(); noGlow(g); g.restore();
  if (sc.title) {
    let sz = 30;
    g.font = `${sz}px "Poppins Bold"`;
    while (g.measureText(sc.title).width + sc.title.length * 6 > 200 && sz > 14) { sz -= 2; g.font = `${sz}px "Poppins Bold"`; }
    text(g, sc.title, cx, cy, sz, "Bold", clamp(ck), "center", 6);
  }
  items.forEach((label, i) => {
    const ang = (-Math.PI / 2) + ((i + 0.5) / items.length) * Math.PI * 2 + (items.length === 3 ? 0.55 : 0);
    const nx = cx + Math.cos(ang) * 560, ny = cy + Math.sin(ang) * 270;
    const k = inOut(seg(p, 0.15 + i * 0.16, 0.4 + i * 0.16));
    if (k <= 0) return;
    g.save(); g.strokeStyle = white(0.5); g.lineWidth = 3; g.beginPath(); g.moveTo(cx + Math.cos(ang) * 118, cy + Math.sin(ang) * 118);
    g.lineTo(lerp(cx + Math.cos(ang) * 118, nx, k), lerp(cy + Math.sin(ang) * 118, ny, k)); g.stroke(); g.restore();
    if (k < 0.7) return;
    const m = outB(seg(k, 0.7, 1));
    g.save(); glow(g, 20, 0.6); g.strokeStyle = white(0.95); g.lineWidth = 4; g.beginPath(); g.arc(nx, ny, 66 * clamp(m, 0, 1.1), 0, 7); g.stroke(); noGlow(g); g.restore();
    icon(g, sc.icons?.[i] ?? "bulb", nx, ny, 0.9 * clamp(m, 0, 1.1), clamp(m), t);
    text(g, label, nx, ny + 104, 20, "SemiBold", clamp(m) * 0.75, "center", 5);
  });
  c.number(960, 150, 90);
  c.label(0, 300, 160); c.label(1, 1620, 160); c.label(2, 300, 960); c.label(3, 1620, 960);
};

const compare: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  stars(g, t, 23, 0.4);
  const items = sc.items ?? ["A", "B"];
  const cols = [520, 1400], fills = [0.15, 1];
  g.save(); g.strokeStyle = white(0.25); g.lineWidth = 2; g.setLineDash([8, 10]); g.beginPath(); g.moveTo(960, 160); g.lineTo(960, 920); g.stroke(); g.restore();
  cols.forEach((x, i) => {
    const k = outC(seg(p, i * 0.18, 0.25 + i * 0.18));
    if (k <= 0) return;
    g.save(); g.globalAlpha *= k;
    if (i === 1) { bloom(g, x, 440, 330, seg(p, 0.5, 0.8)); g.strokeStyle = white(0.9); g.lineWidth = 4; g.beginPath(); g.arc(x, 440, 190, 0, 7); g.stroke(); }
    icon(g, sc.icons?.[i] ?? (i ? "coin" : "gear"), x, 440, 2.3, 1, t);
    text(g, items[i] ?? "", x, 700, 26, "SemiBold", 0.8, "center", 8);
    const m = inOut(seg(p, 0.3 + i * 0.1, 0.8));
    g.strokeStyle = white(0.3); g.lineWidth = 8; g.lineCap = "round"; g.beginPath(); g.moveTo(x - 190, 810); g.lineTo(x + 190, 810); g.stroke();
    glow(g, 14, 0.6); g.strokeStyle = white(0.95); g.beginPath(); g.moveTo(x - 190, 810); g.lineTo(x - 190 + 380 * fills[i]! * m, 810); g.stroke(); noGlow(g);
    text(g, "VALUE", x - 190, 770, 17, "SemiBold", 0.5, "left", 4); text(g, `${Math.round(fills[i]! * 100 * m)}%`, x + 190, 770, 20, "Bold", 0.9, "left");
    g.restore();
  });
  hero(g, 1790, 880, 0.9, outC(seg(p, 0.6, 0.85)), { bulb: 0.7 });
  c.number(960, 90, 70);
  c.label(0, 960, 90); c.label(1, 300, 200); c.label(2, 1620, 200); c.label(3, 960, 1000);
};

const venn: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  stars(g, t, 29, 0.4);
  const items = sc.items ?? [], n = Math.min(3, items.length), r = 250;
  const pos = n === 2 ? [[790, 540], [1130, 540]] : [[790, 450], [1130, 450], [960, 750]];
  pos.slice(0, n).forEach(([x, y], i) => {
    const k = outC(seg(p, i * 0.15, 0.3 + i * 0.15));
    if (k <= 0) return;
    const gr = g.createRadialGradient(x!, y!, 10, x!, y!, r); gr.addColorStop(0, white(0.12 * k)); gr.addColorStop(1, white(0.02 * k));
    g.fillStyle = gr; g.beginPath(); g.arc(x!, y!, r * k, 0, 7); g.fill();
    g.save(); glow(g, 14, 0.5); g.strokeStyle = white(0.95); g.lineWidth = 4; g.beginPath(); g.arc(x!, y!, r * k, 0, 7); g.stroke(); noGlow(g); g.restore();
    const lx = x! + (x! - 960) * 0.45, ly = y! + (y! - 540) * 0.45 - (n === 3 && i === 2 ? -40 : 0);
    text(g, items[i]!, lx, ly, 20, "SemiBold", k * 0.8, "center", 5);
  });
  const mk = outB(seg(p, 0.55, 0.8));
  const cy = n === 2 ? 540 : 580;
  bloom(g, 960, cy, 200, clamp(mk));
  g.save(); glow(g, 30, 0.9); g.fillStyle = white(clamp(mk)); g.beginPath(); g.arc(960, cy, 18 * clamp(mk, 0, 1.2), 0, 7); g.fill(); noGlow(g); g.restore();
  if (sc.title) pill(g, sc.title, 960, cy + 72, clamp(mk));
  c.number(300, 300, 90);
  c.label(0, 960, 90); c.label(1, 300, 200); c.label(2, 1620, 200); c.label(3, 960, 1010);
};

const crowd: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  stars(g, t, 31, 0.5);
  const n = sc.count ?? 8, hot = Math.min(n - 1, sc.hot ?? Math.floor(n / 2));
  const x0 = 380, x1 = 1540, gy = 840;
  const gk = outC(seg(p, 0, 0.2));
  if (sc.goal) { bloom(g, 960, 230, 300, gk); text(g, sc.goal, 960, 230, 92, "Bold", gk); text(g, "THE GOAL", 960, 150, 20, "SemiBold", gk * 0.6, "center", 10); }
  for (let i = 0; i < n; i++) {
    const x = n === 1 ? 960 : lerp(x0, x1, i / (n - 1)), k = outB(seg(p, 0.1 + i * 0.05, 0.3 + i * 0.05));
    if (k <= 0) continue;
    const lit = i === hot ? seg(p, 0.45, 0.7) : 0;
    g.save(); g.strokeStyle = white(0.1 + 0.5 * lit); g.lineWidth = 2; g.setLineDash([6, 10]); g.beginPath(); g.moveTo(960, 300); g.lineTo(x, gy - 150); g.stroke(); g.restore();
    hero(g, x, gy - lit * 40, 1.05 * clamp(k, 0, 1.1), clamp(k), { dim: i !== hot, bulb: i === hot ? lit : undefined, bob: i === hot ? -Math.abs(Math.sin(t * 6)) * 6 * lit : 0 });
  }
  ground(g, gy, 0.5);
  c.number(300, 520, 90);
  c.label(0, 300, 330); c.label(1, 1620, 330); c.label(2, 960, 980); c.label(3, 1620, 980);
};

const SHAPES: Record<CurveShape, (u: number) => number> = {
  rise: (u) => 0.08 + 0.85 * u * u * 0.6 + 0.85 * u * 0.4,
  flat: (u) => 0.05 + 0.07 * u,
  late_jump: (u) => 0.05 + 0.1 * u + 0.8 * clamp((u - 0.62) / 0.14) * u,
  fall: (u) => 0.92 - 0.86 * u,
  wobble_up: (u) => 0.1 + 0.8 * u + 0.05 * Math.sin(u * 22),
  straight: (u) => 0.06 + 0.88 * u,
};

const chart: SceneFn = (c) => {
  const { g, t, p, sc } = c;
  stars(g, t, 37, 0.4);
  const x0 = 300, x1 = 1640, y0 = 900, top = 240;
  const ak = outC(seg(p, 0, 0.15));
  g.save(); g.globalAlpha *= ak; g.strokeStyle = white(0.5); g.lineWidth = 3; g.beginPath(); g.moveTo(x0, top - 20); g.lineTo(x0, y0); g.lineTo(x1 + 30, y0); g.stroke(); g.restore();
  for (let i = 1; i < 5; i++) { g.strokeStyle = white(0.06 * ak); g.beginPath(); g.moveTo(x0, y0 - i * 150); g.lineTo(x1, y0 - i * 150); g.stroke(); }
  const lines = sc.lines?.length ? sc.lines : [{ label: "", shape: "rise" as CurveShape }];
  if (lines.length === 1) {
    g.save(); g.strokeStyle = white(0.3 * ak); g.lineWidth = 3; g.setLineDash([14, 12]); g.beginPath(); g.moveTo(x0, y0 - 40); g.lineTo(x1, top + 40); g.stroke(); g.restore();
  }
  const prog = inOut(seg(p, 0.1, 0.92));
  lines.forEach((ln, li) => {
    const f = SHAPES[ln.shape];
    g.save(); glow(g, 16, 0.6); g.lineWidth = 7; g.strokeStyle = white(0.95); g.lineJoin = "round";
    if (li === 1) g.setLineDash([18, 14]);
    g.beginPath();
    let hx = x0, hy = y0;
    for (let i = 0; i <= 90; i++) { const u = (i / 90) * prog, px = lerp(x0, x1, u), py = y0 - (y0 - top) * f(u); (i ? g.lineTo(px, py) : g.moveTo(px, py)); hx = px; hy = py; }
    g.stroke(); noGlow(g); g.restore();
    if (prog > 0.03) {
      bloom(g, hx, hy, 70, 1);
      g.fillStyle = white(1); g.beginPath(); g.arc(hx, hy, 9, 0, 7); g.fill();
      if (ln.label) text(g, ln.label, clamp(hx - (li ? 130 : 20), 330, 1800), hy + (li ? 70 : -56), 24, "Bold", 0.9, "center", 4);
    }
  });
  c.number(960, 130, 100);
  c.label(0, 520, 330); c.label(1, 1500, 760); c.label(2, 960, 1010); c.label(3, 1500, 160);
};

const KIND: Record<SceneKind, SceneFn> = { journey, night, globe, stairs, feed, grid, machine, hub, compare, venn, crowd, chart };

// -------------------------------------------------------------------- plan

interface Timed { s: number; e: number }
interface Beat { start: number; end: number; sc: GlowScene; labels: Timed[]; num?: { on: Timed; until: Timed } }

export function glowVideo(plan: GlowPlan, words: WordTiming[]): Glow {
  const endS = words[words.length - 1]!.endS + 1.6;
  const starts = sceneStarts(plan);
  const beats: Beat[] = plan.scenes.map((sc, si) => {
    let cursor = starts[si]!;
    const labels = sc.labels.map((l) => { const i = cueIndex(plan, si, l.on, cursor); cursor = i; return cueTime(words, i); });
    let num: Beat["num"];
    if (sc.number) {
      const on = cueIndex(plan, si, sc.number.on, starts[si]!);
      num = { on: cueTime(words, on), until: cueTime(words, cueIndex(plan, si, sc.number.until, on)) };
    }
    return { start: cueTime(words, starts[si]!).s - 0.25, end: 0, sc, labels, num };
  });
  beats.forEach((b, i) => { b.end = beats[i + 1] ? beats[i + 1]!.start : endS; });

  // The background is drawn once: faint dot grid, a light in the middle,
  // dark edges.
  const bg = createCanvas(W, H);
  const gg = bg.getContext("2d");
  gg.fillStyle = "#040404"; gg.fillRect(0, 0, W, H);
  for (let y = 24; y < H; y += 48) for (let x = 24; x < W; x += 48) { gg.fillStyle = white(0.06); gg.fillRect(x, y, 2.2, 2.2); }
  const light = gg.createRadialGradient(W / 2, H * 0.5, 0, W / 2, H * 0.5, 900);
  light.addColorStop(0, "rgba(255,255,255,0.05)"); light.addColorStop(1, "rgba(255,255,255,0)");
  gg.fillStyle = light; gg.fillRect(0, 0, W, H);
  const edge = gg.createRadialGradient(W / 2, H * 0.5, 450, W / 2, H * 0.5, 1250);
  edge.addColorStop(0, "rgba(0,0,0,0)"); edge.addColorStop(1, "rgba(0,0,0,0.75)");
  gg.fillStyle = edge; gg.fillRect(0, 0, W, H);

  return {
    width: W,
    height: H,
    durationS: endS,
    draw(g, t) {
      g.setTransform(1, 0, 0, 1, 0, 0); g.globalAlpha = 1; g.drawImage(bg, 0, 0);
      // Drifting dust: depth that never stops moving. Two layers, near and far,
      // so the whole frame is alive even where a scene has finished drawing.
      for (let i = 0; i < 110; i++) {
        const near = i % 3 === 0;
        const sp = (near ? 26 : 9) + (i % 7) * (near ? 8 : 3);
        const x = ((i * 137.5 + t * sp) % (W + 40)) - 20, y = (i * 61.3 + Math.sin(t * (near ? 0.6 : 0.3) + i) * (near ? 46 : 30)) % H;
        g.fillStyle = white((near ? 0.14 : 0.07) + 0.12 * (0.5 + 0.5 * Math.sin(t * 1.3 + i)));
        const r = near ? 3.8 : 2.4;
        g.fillRect(x, y, r, r);
      }
      // A soft band of light that keeps crossing the frame (about every 5 s).
      {
        const sx = ((t * 230) % (W + 1100)) - 550;
        const band = g.createLinearGradient(sx - 280, 0, sx + 280, 0);
        band.addColorStop(0, "rgba(255,255,255,0)"); band.addColorStop(0.5, "rgba(255,255,255,0.045)"); band.addColorStop(1, "rgba(255,255,255,0)");
        g.fillStyle = band; g.fillRect(0, 0, W, H);
      }
      beats.forEach((b, i) => {
        const last = i === beats.length - 1;
        const fin = seg(t, b.start, b.start + 0.45), fout = last ? seg(t, endS - 0.7, endS) : seg(t, b.end, b.end + 0.3);
        const a = fin * (1 - fout);
        if (a <= 0) return;
        const len = Math.max(0.5, b.end - b.start), lt = t - b.start, p = clamp(lt / len);
        // A scene settles in from slightly closer, drifts on, and eases out:
        // there is never a still frame.
        const z = lerp(1.07, 1, outC(seg(t, b.start, b.start + 0.7))) * (1 + 0.07 * p) * (1 - 0.05 * fout);
        // The camera also wanders a little, so even a held scene is never a still picture.
        const panX = Math.sin(t * 0.42 + i * 1.7) * 22, panY = Math.cos(t * 0.31 + i) * 12;
        g.save(); g.globalAlpha = a; g.translate(W / 2 + panX, H / 2 + panY); g.scale(z, z); g.translate(-W / 2, -H / 2);
        const ctx: Ctx = {
          g, t, p, lt, len, sc: b.sc,
          label(k, x, y) {
            const l = b.sc.labels[k], tm = b.labels[k];
            if (l && tm) pill(g, l.text, x, y, outB(seg(t, tm.s - 0.05, tm.s + 0.4)));
          },
          has(k) { const tm = b.labels[k]; return tm ? outB(seg(t, tm.s - 0.05, tm.s + 0.4)) : 0; },
          number(x, y, size = 100) {
            const n = b.sc.number;
            if (!n || !b.num) return null;
            const k = inOut(seg(t, b.num.on.s, Math.max(b.num.on.s + 0.6, b.num.until.e)));
            const fade = outC(seg(t, b.num.on.s - 0.05, b.num.on.s + 0.35));
            const v = lerp(n.from, n.to, k);
            bloom(g, x, y, size * 2.6, fade * 0.6);
            if (n.label) text(g, n.label, x, y - size * 0.82, Math.max(18, size * 0.24), "SemiBold", fade * 0.65, "center", 8);
            g.save(); glow(g, 24, 0.5);
            let sz = size; g.font = `${sz}px "Poppins Bold"`;
            const label = `${n.prefix ?? ""}${fmt(v)}${n.suffix ?? ""}`;
            while (g.measureText(label).width > 900 && sz > 40) { sz -= 6; g.font = `${sz}px "Poppins Bold"`; }
            text(g, label, x, y, sz, "Bold", fade);
            noGlow(g); g.restore();
            return v;
          },
        };
        KIND[b.sc.kind](ctx);
        g.restore();
      });
    },
  };
}
