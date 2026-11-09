/**
 * The story renderer: takes `render_jobs` rows and turns each one into the
 * finished video.
 *
 *   node renderer/render.ts                      claim and render until the queue is empty, then exit
 *   node renderer/render.ts --spec s.json --out v.mp4   render one spec locally, upload nothing
 *
 * It replaces the script that ran on the old PC as `local-netro-pc` and was
 * lost with its disk (31 Oct 2026). On Fly the machine is stopped while idle:
 * run-agent-jobs starts it when a render is queued, this drains the queue and
 * exits, and the machine stops again -- so it costs only the minutes it works.
 *
 * The spec is `buildRenderSpec` in supabase/functions/_shared/video/story.ts.
 * Captions come from the same module the story engine checks them with
 * (`toAss`), so what was checked is exactly what is burned in.
 */

import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile, copyFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir, hostname } from "node:os";
import { join, resolve } from "node:path";
import { THEMES, checkCaptions, toAss } from "../supabase/functions/_shared/video/captions.ts";
import { FRAME } from "../supabase/functions/_shared/video/types.ts";
import type { Aspect, Issue, Motion, TransitionType, WordTiming } from "../supabase/functions/_shared/video/types.ts";

interface RenderSpec {
  aspect: Aspect;
  fps: number;
  durationS: number;
  scenes: Array<{ id: string; path: string; durationS: number; motion: Motion; transition: TransitionType }>;
  /** `tempo` > 1: play the voice that much faster (the story fitted its
   *  word timings to it already). */
  voice: { path: string; startS: number; tempo?: number } | null;
  words: WordTiming[];
  emphasis: string[];
  captions: boolean;
  captionTheme: string;
  musicBrief: string | null;
  outputPath: string;
  /** A code-drawn video (renderer/draw): no pictures; `scenes` is empty. The
   *  voice and music are storage paths like the story's voice. */
  drawn?: {
    kind: "showdown" | "glow";
    plan: unknown;
    music?: { path: string; startS: number; gainDb?: number; delayS?: number };
  };
}

interface Job {
  id: string;
  spec: RenderSpec;
}

const SUPABASE_URL = process.env.SUPABASE_URL ?? "https://dosszkllkassvyprkhrg.supabase.co";
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const BUCKET = "artifacts";
const FFMPEG = process.env.FFMPEG ?? "ffmpeg";
const FFPROBE = process.env.FFPROBE ?? "ffprobe";
const WORKER = `fly-${process.env.FLY_MACHINE_ID ?? hostname()}`;
/** Seconds a claim is held before another worker may take the job over. */
const LEASE_S = 900;
/** A fade between two pictures, in seconds; a cut is no overlap at all. */
const FADE_S = 0.5;
/** How far a picture zooms over its scene: 1.0 to 1.12. */
const ZOOM = 0.12;

// ------------------------------------------------------------------ plumbing

function run(cmd: string, args: string[], cwd: string): Promise<string> {
  return new Promise((done, fail) => {
    const child = spawn(cmd, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", fail);
    child.on("close", (code) => (code === 0 ? done(out) : fail(new Error(`${cmd} exited ${code}: ${err.slice(-2500)}`))));
  });
}

const headers = () => ({ Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY });

async function rpc<T>(name: string, body: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { ...headers(), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${name} ${res.status}: ${text.slice(0, 300)}`);
  return (text ? JSON.parse(text) : null) as T;
}

async function download(path: string, to: string): Promise<void> {
  const res = await fetch(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${path.split("/").map(encodeURIComponent).join("/")}`, { headers: headers() });
  if (!res.ok) throw new Error(`download ${path}: ${res.status} ${(await res.text()).slice(0, 200)}`);
  await writeFile(to, Buffer.from(await res.arrayBuffer()));
}

async function upload(path: string, from: string): Promise<void> {
  const res = await fetch(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${path.split("/").map(encodeURIComponent).join("/")}`, {
    method: "POST",
    headers: { ...headers(), "Content-Type": "video/mp4", "x-upsert": "true", "cache-control": "3600" },
    body: await readFile(from),
  });
  if (!res.ok) throw new Error(`upload ${path}: ${res.status} ${(await res.text()).slice(0, 200)}`);
}

// ----------------------------------------------------------------- rendering

/** The zoompan expressions for one picture's move over `frames` frames. */
function motion(m: Motion, frames: number): { z: string; x: string; y: string } {
  const t = `on/${Math.max(1, frames - 1)}`;
  const centreX = "iw/2-(iw/zoom/2)";
  const centreY = "ih/2-(ih/zoom/2)";
  switch (m) {
    case "push_in": return { z: `1+${ZOOM}*${t}`, x: centreX, y: centreY };
    case "pull_out": return { z: `${1 + ZOOM}-${ZOOM}*${t}`, x: centreX, y: centreY };
    case "pan_right": return { z: `${1 + ZOOM}`, x: `(iw-iw/zoom)*${t}`, y: centreY };
    case "pan_left": return { z: `${1 + ZOOM}`, x: `(iw-iw/zoom)*(1-${t})`, y: centreY };
    default: return { z: "1", x: "0", y: "0" };
  }
}

/** A low, slow drone made from noise and two sine tones: dark, no melody, and
 *  nothing anyone owns. Used when the brief asks for a drone. */
function droneFilter(total: number): string[] {
  return [
    "-f", "lavfi", "-i", `anoisesrc=color=brown:amplitude=0.5:d=${total}`,
    "-f", "lavfi", "-i", `sine=f=55:d=${total}`,
    "-f", "lavfi", "-i", `sine=f=82.4:d=${total}`,
  ];
}

/** A storage path, or a file on this machine (local test runs). */
async function fetchInput(path: string, to: string): Promise<void> {
  if (existsSync(path)) await copyFile(path, to);
  else await download(path, to);
}

/** A code-drawn video: the plan is drawn frame by frame, the voice and music
 *  are laid under it. Loaded on demand so picture stories never need canvas. */
async function renderDrawn(spec: RenderSpec, work: string, out: string): Promise<Issue[]> {
  const qc: Issue[] = [];
  const { encodeDrawn } = await import("./draw/encode.ts");
  const drawn = spec.drawn!;
  const fps = spec.fps || 30;
  const audio: { voice?: { path: string }; music?: { path: string; startS: number; gainDb?: number; delayS?: number } } = {};
  if (spec.voice?.path) {
    await fetchInput(spec.voice.path, join(work, "voice.audio"));
    audio.voice = { path: join(work, "voice.audio") };
  }
  if (drawn.music?.path) {
    await fetchInput(drawn.music.path, join(work, "music.audio"));
    audio.music = { path: join(work, "music.audio"), startS: drawn.music.startS, gainDb: drawn.music.gainDb, delayS: drawn.music.delayS };
  }
  if (drawn.kind === "showdown") {
    const { showdown } = await import("./draw/showdown.ts");
    const plan = drawn.plan as Parameters<typeof showdown>[0];
    const s = showdown({ ...plan, fps });
    await encodeDrawn(FFMPEG, { width: s.width, height: s.height, fps, durationS: plan.durationS, thuds: s.landings, draw: s.draw }, audio, out);
  } else if (drawn.kind === "glow") {
    const { glowVideo } = await import("./draw/glow.ts");
    if (spec.words.length === 0) throw new Error("a glow explainer needs the voice's word timings");
    const v = glowVideo(drawn.plan as Parameters<typeof glowVideo>[0], spec.words);
    await encodeDrawn(FFMPEG, { width: v.width, height: v.height, fps, durationS: v.durationS, draw: v.draw }, audio, out);
  } else {
    throw new Error(`unknown drawn kind ${String((drawn as { kind: unknown }).kind)}`);
  }
  // What came out, measured: it must have a picture, sound and the planned length.
  const probe = JSON.parse(await run(FFPROBE, ["-v", "error", "-show_entries", "format=duration:stream=codec_type,width,height", "-of", "json", out], work)) as {
    format?: { duration?: string };
    streams?: Array<{ codec_type: string; width?: number; height?: number }>;
  };
  const length = Number(probe.format?.duration ?? 0);
  if (Math.abs(length - spec.durationS) > 1.5) qc.push({ path: "duration", message: `the video is ${length.toFixed(1)}s; the plan was ${spec.durationS}s`, level: "error" });
  if (!probe.streams?.some((s) => s.codec_type === "video")) qc.push({ path: "frame", message: "the video has no picture", level: "error" });
  if (!probe.streams?.some((s) => s.codec_type === "audio")) qc.push({ path: "audio", message: "the video has no sound track", level: "error" });
  // Nothing may sit still: by default every second of a drawn video moves (Abel,
  // 9 Nov 2026). Any picture frozen for more than 0.7 s is reported.
  const frozen = await new Promise<string>((done) => {
    const p = spawn(FFMPEG, ["-nostats", "-i", out, "-vf", "freezedetect=n=0.003:d=0.7", "-an", "-f", "null", "-"], { cwd: work });
    let log = "";
    p.stderr.on("data", (d: Buffer) => (log += d.toString()));
    p.on("close", () => done(log));
    p.on("error", () => done(""));
  });
  for (const m of frozen.matchAll(/freeze_start: ([\d.]+)[\s\S]*?freeze_duration: ([\d.]+)/g)) {
    qc.push({ path: "frozen", message: `the picture is frozen from ${Number(m[1]).toFixed(1)}s for ${Number(m[2]).toFixed(1)}s`, level: "warning" });
  }
  return qc;
}

export async function render(spec: RenderSpec, work: string, out: string, fontsDir?: string): Promise<Issue[]> {
  if (spec.drawn) return renderDrawn(spec, work, out);
  const qc: Issue[] = [];
  const { width: W, height: H } = FRAME[spec.aspect] ?? FRAME["9:16"];
  const fps = spec.fps || 30;
  const scenes = spec.scenes;
  if (scenes.length === 0) throw new Error("the spec has no scenes");

  // 1. Inputs. Each picture keeps its own extension: ffmpeg's still-image
  //    reader (and its -loop) is chosen by it.
  const picture = (i: number) => `scene_${i}.${(/\.(jpe?g|png|webp)$/i.exec(scenes[i]!.path)?.[1] ?? "jpg").toLowerCase()}`;
  for (const [i, s] of scenes.entries()) await download(s.path, join(work, picture(i)));
  const hasVoice = Boolean(spec.voice?.path);
  if (hasVoice) await download(spec.voice!.path, join(work, "voice.audio"));

  // 2. One clip per picture. A fade borrows its overlap from the clip before
  //    it, so the cuts still land where the voice says they should.
  const overlap = scenes.map((s, i) => (i < scenes.length - 1 && s.transition === "fade" ? FADE_S : 0));
  for (const [i, s] of scenes.entries()) {
    const seconds = Math.max(0.3, s.durationS) + overlap[i]!;
    const frames = Math.max(1, Math.round(seconds * fps));
    const m = motion(s.motion, frames);
    await run(FFMPEG, [
      "-hide_banner", "-loglevel", "error", "-y",
      "-loop", "1", "-i", picture(i),
      "-vf", `scale=${W * 2}:${H * 2}:force_original_aspect_ratio=increase,crop=${W * 2}:${H * 2},` +
        `zoompan=z='${m.z}':x='${m.x}':y='${m.y}':d=${frames}:s=${W}x${H}:fps=${fps},setsar=1,format=yuv420p`,
      "-frames:v", String(frames), "-c:v", "libx264", "-preset", "veryfast", "-crf", "17", `clip_${i}.mp4`,
    ], work);
  }

  // 3. Join them: a cut is a concat, a fade an xfade at the scene boundary.
  const total = Math.round(scenes.reduce((a, s) => a + Math.max(0.3, s.durationS), 0) * 100) / 100;
  // Every clip on the same timebase first: newer ffmpeg (9.x) refuses an xfade
  // between a clip (1/15360) and the joined result (1/1000000).
  const parts: string[] = scenes.map((_, i) => `[${i}:v]settb=AVTB[t${i}]`);
  let current = "[t0]";
  let at = 0;
  for (let i = 1; i < scenes.length; i++) {
    at += Math.max(0.3, scenes[i - 1]!.durationS);
    const next = `[t${i}]`;
    const label = `[v${i}]`;
    parts.push(overlap[i - 1]! > 0
      ? `${current}${next}xfade=transition=fade:duration=${overlap[i - 1]}:offset=${(at).toFixed(3)}${label}`
      : `${current}${next}concat=n=2:v=1:a=0${label}`);
    current = label;
  }

  // 4. Captions, from the voice's own word timings.
  let captionFilter = "";
  if (spec.captions && spec.words.length > 0) {
    const theme = THEMES[spec.captionTheme] ?? THEMES.clean!;
    await writeFile(join(work, "captions.ass"), toAss(spec.words, { aspect: spec.aspect, theme, emphasis: spec.emphasis }));
    for (const issue of checkCaptions(spec.words, { aspect: spec.aspect, durationS: total, theme })) {
      // Checked before the render was asked for; here they are notes, not a
      // reason to throw away a finished video.
      qc.push({ ...issue, level: "warning" });
    }
    captionFilter = `,subtitles=f=captions.ass${fontsDir ? `:fontsdir=${fontsDir}` : ""}`;
  }

  // 5. Sound: the voice where the plan put it, a drone under it if asked for.
  const brief = (spec.musicBrief ?? "").toLowerCase();
  const drone = /drone/.test(brief);
  if (spec.musicBrief && !drone) {
    qc.push({ path: "music", message: `no music was added (asked for: ${spec.musicBrief.slice(0, 80)})`, level: "warning" });
  }
  const inputs = scenes.flatMap((_, i) => ["-i", `clip_${i}.mp4`]);
  let audioIn = scenes.length;
  const audio: string[] = [];
  const mix: string[] = [];
  if (hasVoice) {
    inputs.push("-i", "voice.audio");
    const delay = Math.round((spec.voice!.startS ?? 0) * 1000);
    const tempo = spec.voice!.tempo ?? 1;
    const faster = tempo > 1.001 && tempo <= 2 ? `atempo=${tempo.toFixed(3)},` : "";
    audio.push(`[${audioIn}:a]${faster}adelay=${delay}|${delay},apad,atrim=0:${total}[voice]`);
    mix.push("[voice]");
    audioIn++;
  }
  if (drone) {
    inputs.push(...droneFilter(total));
    audio.push(
      `[${audioIn}:a]lowpass=f=180,volume=0.35[n];[${audioIn + 1}:a]volume=0.12,tremolo=f=0.15:d=0.6[s1];[${audioIn + 2}:a]volume=0.06,tremolo=f=0.11:d=0.7[s2];` +
      `[n][s1][s2]amix=inputs=3:normalize=0,afade=t=in:d=2,afade=t=out:st=${Math.max(0, total - 2).toFixed(2)}:d=2,volume=${hasVoice ? 0.5 : 1}[drone]`,
    );
    mix.push("[drone]");
    audioIn += 3;
  }
  if (mix.length === 0) {
    inputs.push("-f", "lavfi", "-i", `anullsrc=r=44100:cl=stereo:d=${total}`);
    mix.push(`[${audioIn}:a]`);
  }
  const audioOut = mix.length > 1
    ? `${mix.join("")}amix=inputs=${mix.length}:duration=first:normalize=0,loudnorm=I=-14:TP=-1.5[a]`
    : `${mix[0]}${mix[0]!.startsWith("[voice") || mix[0] === "[drone]" ? "loudnorm=I=-14:TP=-1.5" : "anull"}[a]`;

  const graph = [...parts, `${current}format=yuv420p${captionFilter}[v]`, ...audio, audioOut].join(";");
  await run(FFMPEG, [
    "-hide_banner", "-loglevel", "error", "-y", ...inputs,
    "-filter_complex", graph,
    "-map", "[v]", "-map", "[a]", "-t", String(total),
    "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-r", String(fps),
    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", out,
  ], work);

  // 6. What came out, measured rather than assumed.
  const probe = JSON.parse(await run(FFPROBE, ["-v", "error", "-show_entries", "format=duration:stream=codec_type,width,height", "-of", "json", out], work)) as {
    format?: { duration?: string };
    streams?: Array<{ codec_type: string; width?: number; height?: number }>;
  };
  const length = Number(probe.format?.duration ?? 0);
  const video = probe.streams?.find((s) => s.codec_type === "video");
  if (Math.abs(length - total) > 1) qc.push({ path: "duration", message: `the video is ${length.toFixed(1)}s; the plan was ${total}s`, level: "error" });
  if (!video || video.width !== W || video.height !== H) qc.push({ path: "frame", message: `the frame is ${video?.width}x${video?.height}, not ${W}x${H}`, level: "error" });
  if (!probe.streams?.some((s) => s.codec_type === "audio")) qc.push({ path: "audio", message: "the video has no sound track", level: "error" });
  return qc;
}

// ---------------------------------------------------------------------- jobs

async function renderJob(job: Job): Promise<void> {
  const work = await mkdtemp(join(tmpdir(), "render-"));
  const out = join(work, "final.mp4");
  try {
    const qc = await render(job.spec, work, out);
    const errors = qc.filter((i) => i.level === "error");
    if (errors.length > 0) {
      await rpc("finish_render_job", { p_job: job.id, p_ok: false, p_path: null, p_qc: qc, p_error: errors.map((e) => e.message).join("; ").slice(0, 500) });
      console.log(`job ${job.id}: failed its checks`, errors.map((e) => e.message));
      return;
    }
    // Uploaded BEFORE the job is marked done, and marked done only once: a
    // story never sees "done" for a file that is not there yet.
    await upload(job.spec.outputPath, out);
    await rpc("finish_render_job", { p_job: job.id, p_ok: true, p_path: job.spec.outputPath, p_qc: qc, p_error: null });
    console.log(`job ${job.id}: done -> ${job.spec.outputPath}`);
  } catch (thrown) {
    const message = thrown instanceof Error ? thrown.message : String(thrown);
    console.error(`job ${job.id}: ${message}`);
    await rpc("finish_render_job", { p_job: job.id, p_ok: false, p_path: null, p_qc: [], p_error: message.slice(0, 500) }).catch(() => {});
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}

async function drain(): Promise<void> {
  for (;;) {
    const claimed = await rpc<Job[] | Job | null>("claim_render_job", { p_worker: WORKER, p_lease: LEASE_S });
    const job = Array.isArray(claimed) ? claimed[0] : claimed;
    if (!job?.id) {
      console.log("queue empty, stopping");
      return;
    }
    console.log(`job ${job.id}: claimed by ${WORKER}`);
    await renderJob(job);
  }
}

// ---------------------------------------------------------------------- main

const args = process.argv.slice(2);
const flag = (name: string) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
};

if (!SERVICE_KEY) {
  console.error("SUPABASE_SERVICE_ROLE_KEY is not set");
  process.exit(1);
}

const specPath = flag("spec");
if (specPath) {
  // Local: one spec, rendered to a file, nothing uploaded or claimed.
  const spec = JSON.parse(await readFile(specPath, "utf8")) as RenderSpec;
  const work = resolve(flag("work") ?? (await mkdtemp(join(tmpdir(), "render-"))));
  await mkdir(work, { recursive: true });
  let fontsDir: string | undefined;
  if (process.platform === "win32") {
    // Windows has no fontconfig alias for Arial; hand libass the font itself.
    fontsDir = "fonts";
    await mkdir(join(work, fontsDir), { recursive: true });
    for (const f of ["arial.ttf", "arialbd.ttf"]) if (existsSync(`C:/Windows/Fonts/${f}`)) await copyFile(`C:/Windows/Fonts/${f}`, join(work, fontsDir, f));
  }
  const out = resolve(flag("out") ?? "final.mp4");
  const qc = await render(spec, work, out, fontsDir);
  console.log(JSON.stringify({ out, qc }, null, 2));
} else {
  await drain();
}
