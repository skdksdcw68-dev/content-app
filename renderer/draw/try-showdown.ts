/**
 * Renders one Stickman Showdown locally, to check the engine against the
 * preview (stickman-v5.mp4):
 *
 *   node renderer/draw/try-showdown.ts <ffmpeg> out.mp4 [music.mp3 startSeconds]
 */
import { encodeDrawn } from "./encode.ts";
import { showdown } from "./showdown.ts";

const [ffmpeg = "ffmpeg", out = "showdown.mp4", music, startS = "0"] = process.argv.slice(2);
const plan = {
  durationS: 20, fps: 60, beatS: 13.6, winner: "OBSESSION",
  losers: [
    { label: "MOTIVATION", dropS: 4.4, tiredS: [0.3, 4.4] as [number, number] },
    { label: "EGO", dropS: 8.4, tiredS: [1.2, 8.4] as [number, number], kick: true },
    { label: "DISCIPLINE", dropS: 12.9, tiredS: [2.5, 12.9] as [number, number] },
  ],
};
const s = showdown(plan);
await encodeDrawn(ffmpeg, { ...s, fps: plan.fps, durationS: plan.durationS, thuds: s.landings }, music ? { music: { path: music, startS: Number(startS) } } : {}, out);
console.log("done", out);
