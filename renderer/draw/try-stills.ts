/** Stills of a designed contest, for checking a spec fast:
 *  node renderer/draw/try-stills.ts spec.json out.png [times...] */
import { readFileSync, writeFileSync } from "node:fs";
import { createCanvas } from "@napi-rs/canvas";
import { loadFonts } from "./encode.ts";
import { showdown } from "./showdown.ts";
import { parseContest } from "../../supabase/functions/_shared/video/drawn.ts";

const [specPath, out, ...times] = process.argv.slice(2);
await loadFonts();
const spec = parseContest(JSON.parse(readFileSync(specPath!, "utf8")));
if (!spec) throw new Error("spec rejected");
const plan = {
  durationS: 20, fps: 60, beatS: 13.6, winner: "WINNER", activity: "custom" as const, custom: spec,
  losers: [
    { label: "ONE", dropS: 4.4, tiredS: [0.3, 4.4] as [number, number] },
    { label: "TWO", dropS: 8.4, tiredS: [1.2, 8.4] as [number, number] },
    { label: "THREE", dropS: 12.9, tiredS: [2.5, 12.9] as [number, number] },
  ],
};
const s = showdown(plan);
const at = (times.length ? times : ["1", "3", "4.2", "4.8", "9", "14.5"]).map(Number).sort((a, b) => a - b);
const sheet = createCanvas(360 * at.length, 640);
const sg = sheet.getContext("2d");
const c = createCanvas(s.width, s.height);
const g = c.getContext("2d");
let t = 0;
for (const [i, target] of at.entries()) {
  for (; t <= target; t += 1 / 30) s.draw(g, t);
  sg.drawImage(c, i * 360, 0, 360, 640);
}
writeFileSync(out!, sheet.toBuffer("image/png"));
console.log("wrote", out);
