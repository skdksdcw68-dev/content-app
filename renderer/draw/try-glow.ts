/**
 * Renders the Glow Explainer fixture locally, to check the engine and the
 * plan checks against the preview (first-100-videos.mp4):
 *
 *   node renderer/draw/try-glow.ts <ffmpeg> out.mp4 [bed.mp3]
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { parseGlowPlan } from "../../supabase/functions/_shared/video/drawn.ts";
import { encodeDrawn } from "./encode.ts";
import { glowVideo } from "./glow.ts";

const dir = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const [ffmpeg = "ffmpeg", out = "glow.mp4", bed] = process.argv.slice(2);
const parsed = parseGlowPlan(JSON.parse(readFileSync(join(dir, "first-100.plan.json"), "utf8")));
if (!parsed.ok) throw new Error(JSON.stringify(parsed.issues));
if (parsed.issues.length) console.log("plan notes:", parsed.issues);
const words = JSON.parse(readFileSync(join(dir, "first-100.words.json"), "utf8"));
const v = glowVideo(parsed.value, words);
await encodeDrawn(
  ffmpeg,
  { width: v.width, height: v.height, fps: 30, durationS: v.durationS, draw: v.draw },
  { voice: { path: join(dir, "first-100.voice.mp3") }, music: bed ? { path: bed, startS: 0, gainDb: -18 } : undefined },
  out,
);
console.log("done", out, v.durationS.toFixed(1) + "s");
