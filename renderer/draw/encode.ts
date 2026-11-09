/**
 * Draws a code-made video frame by frame and pipes the pixels into ffmpeg,
 * together with the sound: soft thuds where the picture says something lands,
 * plus an optional music file started at an offset.
 */
import { spawn } from "node:child_process";
import { createCanvas, GlobalFonts } from "@napi-rs/canvas";
import type { SKRSContext2D } from "@napi-rs/canvas";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const FONTS = join(dirname(fileURLToPath(import.meta.url)), "fonts");
let fontsLoaded = false;

/** Registers the bundled fonts once. */
export function loadFonts(): void {
  if (fontsLoaded) return;
  fontsLoaded = true;
  GlobalFonts.registerFromPath(join(FONTS, "Oswald.ttf"), "Oswald");
  for (const w of ["Medium", "SemiBold", "Bold"]) GlobalFonts.registerFromPath(join(FONTS, `Poppins-${w}.ttf`), `Poppins ${w}`);
}

export interface DrawnVideo {
  width: number;
  height: number;
  fps: number;
  durationS: number;
  /** Seconds when something lands, for the thud under it. */
  thuds?: number[];
  draw(g: SKRSContext2D, t: number): void;
}

export interface DrawnAudio {
  /** A music file, started `startS` into it. */
  music?: { path: string; startS: number; gainDb?: number };
  /** A voice-over, played from the start. */
  voice?: { path: string };
}

/** Renders `video` to `out` (H.264 + AAC). Resolves when ffmpeg is done. */
export async function encodeDrawn(ffmpeg: string, video: DrawnVideo, audio: DrawnAudio, out: string): Promise<void> {
  loadFonts();
  const { width: W, height: H, fps, durationS: DUR } = video;
  const frames = Math.round(fps * DUR);

  const thud = (video.thuds ?? [])
    .map((T) => `if(gte(t,${T.toFixed(3)}),0.7*sin(2*PI*55*(t-${T.toFixed(3)}))*exp(-(t-${T.toFixed(3)})*10),0)`)
    .join("+") || "0";
  // Input 0 is the picture; the rest are audio, numbered in the order added.
  const inputs: string[] = [];
  const labels: string[] = [];
  const add = (args: string[], filter: string) => {
    inputs.push(...args);
    labels.push(`[${labels.length + 1}:a]${filter}[a${labels.length}]`);
  };
  add(["-f", "lavfi", "-i", `aevalsrc='${thud}':s=44100:d=${DUR}`], "aformat=channel_layouts=stereo,volume=0.8");
  if (audio.music) {
    add(
      ["-ss", String(audio.music.startS), "-t", String(DUR), "-i", audio.music.path],
      `aformat=sample_rates=44100:channel_layouts=stereo,volume=${audio.music.gainDb ?? -1}dB,afade=t=in:d=0.2,afade=t=out:st=${Math.max(0, DUR - 1.2)}:d=1.2`,
    );
  }
  if (audio.voice) add(["-i", audio.voice.path], "aformat=sample_rates=44100:channel_layouts=stereo");
  const ins = labels.map((_, i) => `[a${i}]`).join("");
  const graph = `${labels.join(";")};${ins}amix=inputs=${labels.length}:normalize=0,alimiter=limit=0.95[a]`;

  const ff = spawn(ffmpeg, [
    "-y", "-v", "error",
    "-f", "rawvideo", "-pix_fmt", "rgba", "-s", `${W}x${H}`, "-r", String(fps), "-i", "pipe:0",
    ...inputs,
    "-filter_complex", graph, "-map", "0:v", "-map", "[a]",
    "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
    "-c:a", "aac", "-b:a", "160k", "-t", String(DUR), "-movflags", "+faststart", out,
  ], { stdio: ["pipe", "inherit", "pipe"] });
  let err = "";
  ff.stderr!.on("data", (d) => (err += d));
  const closed = new Promise<void>((done, fail) => {
    ff.on("error", fail);
    ff.on("close", (code) => (code === 0 ? done() : fail(new Error(`ffmpeg exited ${code}: ${err.slice(-600)}`))));
  });

  const canvas = createCanvas(W, H);
  const g = canvas.getContext("2d");
  for (let n = 0; n < frames; n++) {
    video.draw(g, n / fps);
    const buf = Buffer.from(g.getImageData(0, 0, W, H).data.buffer);
    if (!ff.stdin!.write(buf)) await new Promise((r) => ff.stdin!.once("drain", r));
  }
  ff.stdin!.end();
  await closed;
}
