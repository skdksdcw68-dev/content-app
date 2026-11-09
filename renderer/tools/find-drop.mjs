// Finds a track's "drop": the moment the bass comes back hard after a quieter
// stretch (the rule from the stickman previews, 8 Nov 2026: bass band under
// 120 Hz, RMS per 0.1 s, the biggest jump from the 2 s before to the 1 s after).
//
//   node renderer/tools/find-drop.mjs <ffmpeg> track.mp3        prints {"drop_s": 13.1, "dur_s": 30, "score": ...}
import { spawn } from "node:child_process";

const [ffmpeg, file] = process.argv.slice(2);
if (!ffmpeg || !file) { console.error("usage: find-drop.mjs <ffmpeg> <file>"); process.exit(1); }
const RATE = 4000, STEP = 0.1;
const chunks = [];
await new Promise((done, fail) => {
  const p = spawn(ffmpeg, ["-v", "error", "-i", file, "-ac", "1", "-ar", String(RATE), "-af", "lowpass=f=120", "-f", "f32le", "-"], { stdio: ["ignore", "pipe", "inherit"] });
  p.stdout.on("data", (d) => chunks.push(d));
  p.on("error", fail);
  p.on("close", (c) => (c === 0 ? done() : fail(new Error(`ffmpeg exited ${c}`))));
});
const buf = Buffer.concat(chunks);
const samples = new Float32Array(buf.buffer, buf.byteOffset, Math.floor(buf.length / 4));
const win = Math.round(RATE * STEP), n = Math.floor(samples.length / win);
const rms = [];
for (let i = 0; i < n; i++) { let s = 0; for (let j = 0; j < win; j++) { const v = samples[i * win + j]; s += v * v; } rms.push(Math.sqrt(s / win)); }
const mean = (a, b) => { let s = 0, c = 0; for (let i = Math.max(0, a); i < Math.min(n, b); i++) { s += rms[i]; c++; } return c ? s / c : 0; };
const dur = n * STEP;
let best = { t: 0, score: -1 };
for (let i = Math.round(4 / STEP); i < n - Math.round(3 / STEP); i++) {
  const before = mean(i - Math.round(2 / STEP), i), after = mean(i, i + Math.round(1 / STEP));
  const score = after - before;
  if (score > best.score) best = { t: i * STEP, score };
}
console.log(JSON.stringify({ drop_s: Math.round(best.t * 10) / 10, dur_s: Math.round(dur * 10) / 10, score: Math.round(best.score * 1000) / 1000 }));
