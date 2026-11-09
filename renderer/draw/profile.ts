/** Times each scene of a spec: node renderer/draw/profile.ts spec.json */
import { readFileSync } from "node:fs";
import { createCanvas } from "@napi-rs/canvas";
import { loadFonts } from "./encode.ts";
import { glowVideo } from "./glow.ts";
import { sceneStarts, cueTime } from "../../supabase/functions/_shared/video/drawn.ts";

loadFonts();
const spec = JSON.parse(readFileSync(process.argv[2]!, "utf8"));
const plan = spec.drawn.plan, words = spec.words;
const v = glowVideo(plan, words);
const c = createCanvas(v.width, v.height), g = c.getContext("2d");
const starts = sceneStarts(plan);
plan.scenes.forEach((sc: { kind: string }, i: number) => {
  const a = cueTime(words, starts[i]!).s, b = i + 1 < starts.length ? cueTime(words, starts[i + 1]!).s : v.durationS;
  const t0 = performance.now();
  const N = 12;
  for (let k = 0; k < N; k++) v.draw(g, a + ((b - a) * (k + 0.5)) / N);
  const ms = (performance.now() - t0) / N;
  console.log(`${String(i).padStart(2)} ${sc.kind.padEnd(8)} ${ms.toFixed(0).padStart(5)} ms/frame`);
});
