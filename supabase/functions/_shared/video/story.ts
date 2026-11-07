import type { Aspect, Issue, Motion, Scene, StoryPlan, TransitionType, WordTiming } from "./types.ts";
import { checkCoverage, timeScenesToVoice } from "./storyboard.ts";
import { planStory } from "./planner.ts";
import { productionFor, withCaptionChoice, type Production, type StyleRow } from "./style.ts";
import type { Review } from "./review.ts";
import type { Spoken } from "./voice.ts";

/**
 * The story job as a state machine: topic in, finished video out.
 *
 * `stepStory` does ONE unit of work and returns. The caller persists the
 * returned state and calls again later, which is what lets a story survive a
 * closed app, a dead worker and a function that times out: every call starts
 * from the state, never from memory. Anything that spends money is followed by
 * `save` BEFORE the next thing happens, so a crash cannot lose the handle of
 * something already paid for and buy it twice.
 *
 * Providers are injected (`StoryDeps`), so this file never learns which image
 * model, voice or storage it is talking to -- and the whole flow, including a
 * crash in the middle, runs under test with fakes.
 */

export interface StoryRequest {
  topic: string;
  styleSlug: string;
  durationS?: number;
  /** User's choice; the style's default when absent. */
  narration?: boolean;
  aspect?: Aspect;
  brandContext?: string;
  /** How every picture is drawn, chosen on the chat card (one of the style's
   *  CategoryLooks); the style's own `visual_style` when absent. */
  look?: string;
  /** The ElevenLabs voice chosen on the card; the server's default when absent. */
  voiceId?: string;
  /** A `SeriesCaption` id from the card; "none" turns captions off. */
  captionStyle?: string;
  /** What the brief read from the request and any pictures they sent: tone,
   *  pace, structure. Told to the writer after the topic. */
  direction?: string;
}

export type Phase = "plan" | "voice" | "images" | "render" | "finish" | "done" | "failed";

export interface SceneState {
  status: "pending" | "submitted" | "ready" | "passed" | "accepted" | "failed";
  attempts: number;
  /** Provider's handle for the picture in flight. */
  handle?: unknown;
  path?: string;
  /** What the reviewer asked to change, for the next attempt's prompt. */
  feedback: string | null;
  /** Problems that remained when a picture was accepted anyway. */
  problems: string[];
  costUsd: number;
  announced: boolean;
}

export interface StoryState {
  phase: Phase;
  request: StoryRequest;
  production?: Production;
  plan?: StoryPlan;
  words?: WordTiming[];
  /** `tempo` above 1 is how much faster the renderer plays the recording so
   *  it fits the length that was asked for; the word timings are already
   *  scaled to it. */
  voice?: { path: string; durationS: number; tempo?: number };
  totalS?: number;
  scenes: Record<string, SceneState>;
  renderJobId?: string;
  renderAnnounced?: boolean;
  finalPath?: string;
  spentUsd: number;
  /** Everything said to the person that they might need again. */
  warnings: string[];
  error?: string;
}

export interface RenderSpec {
  aspect: Aspect;
  fps: number;
  durationS: number;
  scenes: Array<{ id: string; path: string; durationS: number; motion: Motion; transition: TransitionType }>;
  voice: { path: string; startS: number; tempo?: number } | null;
  words: WordTiming[];
  emphasis: string[];
  captions: boolean;
  captionTheme: "clean" | "bold" | "horror";
  musicBrief: string | null;
  /** Where the worker must put the finished file. */
  outputPath: string;
}

export type ImagePoll =
  | { state: "running" }
  | { state: "done"; bytes: Uint8Array; mime: string }
  | { state: "failed"; error: string; retryable: boolean };

export interface StoryDeps {
  userId: string;
  runId: string;
  style(slug: string): Promise<StyleRow | null>;
  ask(system: string, user: string): Promise<string>;
  speak(text: string): Promise<Spoken>;
  image: {
    submit(prompt: string, o: { aspect: Aspect }): Promise<{ handle: unknown; costUsd: number }>;
    poll(handle: unknown): Promise<ImagePoll>;
  };
  /** A reviewer that is NOT the image model. */
  review(a: { imageUrl: string; scene: Scene; plan: StoryPlan; production: Production }): Promise<{ review: Review; costUsd: number }>;
  imageSize(bytes: Uint8Array): { width: number; height: number } | null;
  store: {
    put(path: string, bytes: Uint8Array, mime: string): Promise<void>;
    signedUrl(path: string): Promise<string>;
  };
  /** A line in the conversation. */
  /** A step along the way ("Making picture 3 of 6"). Shown folded into one
   *  progress block, never as a message of its own. */
  say(text: string): Promise<void>;
  /** How it ended, when it ended badly: a message the person must see, not a
   *  step to fold away. Falls back to `say`. */
  sayOutcome?(text: string): Promise<void>;
  save(state: StoryState): Promise<void>;
  queueRender(spec: RenderSpec): Promise<string>;
  renderStatus(id: string): Promise<{ status: "queued" | "rendering" | "done" | "failed"; outputPath?: string; error?: string; qc?: Issue[] }>;
  /** Make the finished file the run's result (the artifact in the chat). */
  publish(a: { finalPath: string; plan: StoryPlan; production: Production; warnings: string[]; durationS: number }): Promise<void>;
  /** Limits. */
  limits?: Partial<Limits>;
  assetRecord?(a: { sceneId: string | null; kind: "image" | "voice" | "final"; path: string; costUsd: number; attempt: number; meta?: Record<string, unknown> }): Promise<void>;
}

export interface Limits {
  /** Picture attempts per scene before the best one is accepted. */
  attemptsPerScene: number;
  /** Pictures made at once. */
  concurrency: number;
  /** Everything this story may spend, dollars. */
  budgetUsd: number;
  minScore: number;
  /** Plan retries. */
  planRetries: number;
}

const DEFAULTS: Limits = { attemptsPerScene: 2, concurrency: 6, budgetUsd: 3, minScore: 0.6, planRetries: 2 };

export interface StepResult {
  state: StoryState;
  /** Seconds until this should be called again. */
  waitS: number;
  done: boolean;
}

export function newStory(request: StoryRequest): StoryState {
  return { phase: "plan", request, scenes: {}, spentUsd: 0, warnings: [] };
}

export async function stepStory(deps: StoryDeps, input: StoryState): Promise<StepResult> {
  const state: StoryState = structuredClone(input);
  const limits = { ...DEFAULTS, ...deps.limits };
  switch (state.phase) {
    case "plan": return await planPhase(deps, state, limits);
    case "voice": return await voicePhase(deps, state);
    case "images": return await imagesPhase(deps, state, limits);
    case "render": return await renderPhase(deps, state);
    case "finish": return await finishPhase(deps, state);
    default: return { state, waitS: 0, done: true };
  }
}

async function fail(deps: StoryDeps, state: StoryState, message: string): Promise<StepResult> {
  state.phase = "failed";
  state.error = message;
  await (deps.sayOutcome ?? deps.say)(message);
  return { state, waitS: 0, done: true };
}

// ----------------------------------------------------------------------- plan

async function planPhase(deps: StoryDeps, state: StoryState, limits: Limits): Promise<StepResult> {
  const style = await deps.style(state.request.styleSlug);
  if (!style) return fail(deps, state, `I don't know a style called “${state.request.styleSlug}”.`);

  const production = productionFor(style, {
    ...(state.request.aspect ? { aspect: state.request.aspect } : {}),
    ...(state.request.durationS ? { durationS: state.request.durationS } : {}),
    ...(state.request.narration !== undefined ? { narration: state.request.narration } : {}),
  });
  if (production.support.level === "unsupported") {
    return fail(deps, state, `I can't make “${style.name ?? style.slug}” videos yet: ${production.support.reason}.`);
  }
  // What the person picked on the card is stronger than the style's default.
  if (state.request.look?.trim()) production.visualStyle = state.request.look.trim();
  if (state.request.captionStyle) withCaptionChoice(production, state.request.captionStyle);
  if (production.support.level === "partial") state.warnings.push(production.support.reason);
  state.warnings.push(...production.notes);

  await deps.say(`📝 Planning a ${production.durationS}-second ${style.name ?? style.slug} story about “${state.request.topic}”…`);
  const planned = await planStory({
    production,
    request: {
      topic: state.request.topic,
      ...(state.request.brandContext ? { brandContext: state.request.brandContext } : {}),
      ...(state.request.direction ? { direction: state.request.direction } : {}),
    },
    ask: deps.ask,
    retries: limits.planRetries,
  });
  if (!planned.plan) {
    return fail(deps, state, "I couldn't get a usable plan for that story after a few tries, so I stopped before spending anything on pictures.");
  }

  state.production = production;
  state.plan = planned.plan;
  for (const s of planned.plan.scenes) {
    state.scenes[s.id] = { status: "pending", attempts: 0, feedback: null, problems: [], costUsd: 0, announced: false };
  }
  state.phase = production.narration ? "voice" : "images";
  if (!production.narration) assignEvenDurations(state);

  const n = planned.plan.scenes.length;
  await deps.say(`✅ Plan ready: “${planned.plan.title}”, ${n} scenes.\nHook: ${planned.plan.hook}`);
  await deps.save(state);
  return { state, waitS: 1, done: false };
}

/** The pause after the last word before the video ends. */
const TAIL_S = 0.6;
/** The fastest the voice is played to fit a length. */
const MAX_TEMPO = 1.2;

function assignEvenDurations(state: StoryState): void {
  const plan = state.plan!;
  const target = state.production!.durationS;
  const each = Math.round((target / plan.scenes.length) * 100) / 100;
  const scenes = plan.scenes.map((s, i) => ({
    ...s,
    durationS: i === plan.scenes.length - 1 ? Math.round((target - each * (plan.scenes.length - 1)) * 100) / 100 : each,
  }));
  state.plan = { ...plan, scenes };
  state.totalS = target;
}

// ---------------------------------------------------------------------- voice

async function voicePhase(deps: StoryDeps, state: StoryState): Promise<StepResult> {
  const plan = state.plan!;
  const production = state.production!;
  const script = plan.scenes.map((s) => s.narration).filter(Boolean).join(" ");
  if (!script.trim()) return fail(deps, state, "The plan had no narration to record, so I stopped.");

  await deps.say("🎙️ Recording the voiceover…");
  const spoken = await deps.speak(script);
  state.spentUsd += 0; // the voice is billed to the provider account, recorded in assetRecord
  if (spoken.words.length === 0) {
    // Without the voice's own timing there is nothing honest to cut or caption by.
    return fail(
      deps,
      state,
      `The voiceover didn't work (${spoken.problem ?? "no word timing came back"}), and without the voice's own timing I can't cut the pictures or time the captions. I stopped before making any.`,
    );
  }

  const path = `${deps.userId}/story-${deps.runId}/voice.mp3`;
  await deps.store.put(path, spoken.audio, spoken.mime);
  await deps.assetRecord?.({ sceneId: null, kind: "voice", path, costUsd: 0, attempt: 1, meta: { characters: spoken.characters, durationS: spoken.durationS } });

  // Running long: play the recording a little faster (the renderer's atempo,
  // which costs nothing, where a second recording costs the voice again)
  // rather than hand back a longer video than was asked for. Up to 1.2x still
  // sounds like the same narrator; past that the length is told honestly.
  const speechEnd = spoken.words[spoken.words.length - 1]?.endS ?? 0;
  const room = Math.max(1, production.durationS - TAIL_S);
  const tempo = speechEnd > room * 1.03 ? Math.round(Math.min(MAX_TEMPO, speechEnd / room) * 1000) / 1000 : 1;
  const words = tempo > 1
    ? spoken.words.map((w) => ({ ...w, startS: w.startS / tempo, endS: w.endS / tempo }))
    : spoken.words;

  const fitted = timeScenesToVoice(plan, words, { tailS: TAIL_S });
  const errors = fitted.issues.filter((i) => i.level === "error");
  if (errors.length > 0) return fail(deps, state, `The voice and the plan didn't line up: ${errors[0]!.message}.`);
  for (const w of fitted.issues) state.warnings.push(w.message);
  for (const c of checkCoverage(fitted.plan, production.durationS, production.durationS * 0.2)) state.warnings.push(c.message);

  state.plan = fitted.plan;
  state.words = words;
  state.voice = {
    path,
    durationS: spoken.durationS ? spoken.durationS / tempo : fitted.totalS,
    ...(tempo > 1 ? { tempo } : {}),
  };
  state.totalS = fitted.totalS;
  state.phase = "images";

  const off = Math.abs(fitted.totalS - production.durationS) > Math.max(1.5, production.durationS * 0.1);
  await deps.say(
    `✅ Voiceover recorded: ${fitted.totalS.toFixed(0)} seconds` +
      (off && fitted.totalS < production.durationS
        ? `. You asked for ${production.durationS}; the story came out shorter.`
        : off
        ? `. You asked for ${production.durationS}; even read a little faster, the story needs this long.`
        : tempo > 1
        ? `, read a little faster to fit the ${production.durationS} you asked for.`
        : "."),
  );
  await deps.save(state);
  return { state, waitS: 1, done: false };
}

// --------------------------------------------------------------------- images

/** Everything the picture model needs in one prompt: the scene, the recurring
 *  people and places (so they look the same), the style, and what the reviewer
 *  said was wrong last time. */
export function composeImagePrompt(plan: StoryPlan, scene: Scene, production: Production, feedback: string | null): string {
  const who = scene.characters
    .map((n) => plan.characters.find((c) => c.name.toLowerCase() === n.toLowerCase()))
    .filter((c): c is { name: string; description: string } => !!c)
    .map((c) => `${c.name}: ${c.description}`);
  const where = scene.location ? plan.locations.find((l) => l.name.toLowerCase() === scene.location!.toLowerCase()) : undefined;
  return [
    scene.imagePrompt,
    who.length ? `Characters (keep identical across scenes): ${who.join("; ")}.` : "",
    where ? `Setting: ${where.name}: ${where.description}.` : "",
    production.visualStyle ? `Visual style: ${production.visualStyle}.` : "",
    `${production.aspect === "9:16" ? "Vertical 9:16" : production.aspect === "16:9" ? "Horizontal 16:9" : "Square"} composition, subject clear, no text, no logos, no watermarks.`,
    feedback ? `Fix from the last attempt: ${feedback}` : "",
  ].filter(Boolean).join(" ");
}

async function imagesPhase(deps: StoryDeps, state: StoryState, limits: Limits): Promise<StepResult> {
  const plan = state.plan!;
  const production = state.production!;
  const total = plan.scenes.length;
  const numberOf = (id: string) => plan.scenes.findIndex((s) => s.id === id) + 1;
  let busy = 0;
  // Free places for new pictures, counted once up front: a picture finishing
  // during this step frees its place for the next step, not this one.
  let slots = limits.concurrency - Object.values(state.scenes).filter((s) => s.status === "submitted").length;

  // Every scene moves at once. A picture model can hold the request open for
  // the whole generation (GPT Image 2 does, ~40 s), so doing the scenes one
  // after another made a 12-picture story take as many minutes as pictures.
  const advance = async (scene: StoryPlan["scenes"][number]): Promise<void> => {
    const st = state.scenes[scene.id]!;
    const n = numberOf(scene.id);

    if (st.status === "submitted") {
      const polled = await deps.image.poll(st.handle);
      if (polled.state === "running") {
        busy++;
      } else if (polled.state === "failed") {
        if (polled.retryable && st.attempts < limits.attemptsPerScene) {
          st.status = "pending";
          st.handle = undefined;
        } else if (st.path) {
          // An earlier attempt exists: keep it rather than lose the scene.
          st.status = "accepted";
          st.problems.push("a later attempt failed to generate");
        } else {
          st.status = "failed";
          await deps.say(`⚠️ Picture ${n} of ${total} couldn't be made: ${polled.error}`);
        }
        await deps.save(state);
      } else {
        const path = `${deps.userId}/story-${deps.runId}/${scene.id}-v${st.attempts}.${extFor(polled.mime)}`;
        await deps.store.put(path, polled.bytes, polled.mime);
        // Measurable checks before any model is asked: a wrong shape never
        // reaches the reviewer.
        const size = deps.imageSize(polled.bytes);
        const wrongShape = size && (production.aspect === "9:16" ? size.height <= size.width : production.aspect === "16:9" ? size.width <= size.height : false);
        if (!size || size.width < 256 || size.height < 256) {
          st.feedback = "the picture was unreadable or too small";
          st.status = st.attempts < limits.attemptsPerScene ? "pending" : "failed";
        } else if (wrongShape) {
          st.feedback = `the picture must be ${production.aspect}, it came back ${size.width}x${size.height}`;
          st.status = st.attempts < limits.attemptsPerScene ? "pending" : "accepted";
          st.path = path; // usable: the renderer crops to fit
          if (st.status === "accepted") st.problems.push("wrong shape; cropped to fit");
        } else {
          st.path = path;
          st.status = "ready";
        }
        st.handle = undefined;
        await deps.assetRecord?.({ sceneId: scene.id, kind: "image", path, costUsd: st.costUsd, attempt: st.attempts });
        await deps.save(state);
      }
    }

    if (st.status === "ready") {
      await deps.say(`🔎 Reviewing picture ${n} of ${total}…`);
      const url = await deps.store.signedUrl(st.path!);
      const { review, costUsd } = await deps.review({ imageUrl: url, scene, plan, production });
      state.spentUsd += costUsd;
      st.costUsd += costUsd;
      const lowScore = review.score !== null && review.score < limits.minScore;
      if (review.verdict === "PASS" && review.problems.length === 0 && !lowScore) {
        st.status = "passed";
        await deps.say(`✅ Picture ${n} of ${total} passed review.`);
      } else if (review.verdict === "ESCALATE" || st.attempts >= limits.attemptsPerScene) {
        st.status = "accepted";
        st.problems = review.problems.length ? review.problems : ["did not fully pass review"];
        state.warnings.push(`Picture ${n}: ${st.problems.join("; ")}`);
        await deps.say(`⚠️ Picture ${n} of ${total} isn't perfect (${st.problems[0]}), but it was the best of ${st.attempts} tries, so I'm using it.`);
      } else {
        st.feedback = [review.correction, ...review.problems].filter(Boolean).join(" | ") || "improve on the previous attempt";
        st.status = "pending";
        await deps.say(`🔁 Picture ${n} of ${total} needs another go: ${review.problems[0] ?? "it didn't match the scene"}.`);
      }
      await deps.save(state);
    }

    if (st.status === "pending") {
      if (slots <= 0) return;
      if (state.spentUsd >= limits.budgetUsd) {
        st.status = st.path ? "accepted" : "failed";
        state.warnings.push(`The $${limits.budgetUsd} budget for this story was reached at picture ${n}.`);
        await deps.save(state);
        return;
      }
      slots--;
      if (!st.announced) {
        await deps.say(`🖼️ Making picture ${n} of ${total}: ${shorten(scene.visual)}`);
        st.announced = true;
      }
      const prompt = composeImagePrompt(plan, scene, production, st.feedback);
      const made = await deps.image.submit(prompt, { aspect: production.aspect });
      st.attempts += 1;
      st.handle = made.handle;
      st.costUsd += made.costUsd;
      state.spentUsd += made.costUsd;
      st.status = "submitted";
      // Money is spent: record the handle before anything else can go wrong.
      await deps.save(state);
      busy++;
    }
  };

  // Wait for every scene, even if one throws: abandoning the others mid-flight
  // would leave paid-for pictures unrecorded, and the retry would buy them again.
  const results = await Promise.allSettled(plan.scenes.map(advance));
  const rejected = results.find((r): r is PromiseRejectedResult => r.status === "rejected");
  if (rejected) {
    await deps.save(state);
    throw rejected.reason;
  }

  const all = Object.values(state.scenes);
  const settled = all.every((s) => s.status === "passed" || s.status === "accepted" || s.status === "failed");
  if (settled) {
    const missing = plan.scenes.filter((s) => state.scenes[s.id]!.status === "failed" || !state.scenes[s.id]!.path);
    if (missing.length > 0) {
      return fail(deps, state, `${missing.length} of ${total} pictures couldn't be made, so I stopped instead of delivering a video with holes in it.`);
    }
    state.phase = "render";
    await deps.say(`🎞️ All ${total} pictures are ready. Putting it together: motion, voice, captions and music…`);
    await deps.save(state);
    return { state, waitS: 1, done: false };
  }
  return { state, waitS: busy > 0 ? 8 : 2, done: false };
}

function extFor(mime: string): string {
  return /jpe?g/.test(mime) ? "jpg" : /webp/.test(mime) ? "webp" : "png";
}
function shorten(s: string): string {
  return s.length > 90 ? `${s.slice(0, 87)}…` : s;
}

// --------------------------------------------------------------------- render

const MOTIONS: Motion[] = ["push_in", "pan_right", "pull_out", "pan_left"];

export function buildRenderSpec(state: StoryState, userId: string, runId: string): RenderSpec {
  const plan = state.plan!;
  const production = state.production!;
  const scenes = plan.scenes.map((s, i) => ({
    id: s.id,
    path: state.scenes[s.id]!.path!,
    durationS: s.durationS ?? production.sceneS,
    // The planner's choice, but never the same move three scenes running.
    motion: (s.motion === "none" ? "none" : i > 0 && s.motion === plan.scenes[i - 1]!.motion ? MOTIONS[i % MOTIONS.length]! : s.motion),
    transition: s.transition ?? production.defaultTransition,
  }));
  const total = Math.round(scenes.reduce((a, s) => a + s.durationS, 0) * 100) / 100;
  return {
    aspect: production.aspect,
    fps: 30,
    durationS: total,
    scenes,
    voice: state.voice
      ? { path: state.voice.path, startS: 0, ...(state.voice.tempo && state.voice.tempo > 1 ? { tempo: state.voice.tempo } : {}) }
      : null,
    words: state.words ?? [],
    emphasis: plan.scenes.flatMap((s) => s.emphasis),
    captions: production.captions.enabled && (state.words?.length ?? 0) > 0,
    captionTheme: production.captions.themeName,
    musicBrief: production.musicBrief,
    outputPath: `${userId}/story-${runId}/final.mp4`,
  };
}

async function renderPhase(deps: StoryDeps, state: StoryState): Promise<StepResult> {
  if (!state.renderJobId) {
    state.renderJobId = await deps.queueRender(buildRenderSpec(state, deps.userId, deps.runId));
    await deps.save(state);
    return { state, waitS: 10, done: false };
  }
  const status = await deps.renderStatus(state.renderJobId);
  if (status.status === "failed") {
    const checks = (status.qc ?? []).filter((i) => i.level === "error").map((i) => i.message).slice(0, 2).join("; ");
    // A render that never finished has no checks to quote: say what happened.
    return fail(
      deps,
      state,
      checks
        ? `The final video didn't pass its checks (${checks}). Nothing was published.`
        : (status.error || "The video could not be finished. Nothing was published."),
    );
  }
  if (status.status === "done" && status.outputPath) {
    state.finalPath = status.outputPath;
    for (const i of status.qc ?? []) if (i.level === "warning") state.warnings.push(i.message);
    state.phase = "finish";
    await deps.save(state);
    return { state, waitS: 1, done: false };
  }
  if (!state.renderAnnounced) {
    state.renderAnnounced = true;
    await deps.save(state);
  }
  return { state, waitS: 10, done: false };
}

// --------------------------------------------------------------------- finish

async function finishPhase(deps: StoryDeps, state: StoryState): Promise<StepResult> {
  await deps.assetRecord?.({ sceneId: null, kind: "final", path: state.finalPath!, costUsd: 0, attempt: 1 });
  await deps.publish({
    finalPath: state.finalPath!,
    plan: state.plan!,
    production: state.production!,
    warnings: state.warnings,
    durationS: state.totalS ?? state.production!.durationS,
  });
  state.phase = "done";
  await deps.save(state);
  return { state, waitS: 0, done: true };
}
