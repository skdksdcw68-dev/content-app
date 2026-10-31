import type { ClipLimits, Issue, Motion, Parsed, Scene, StoryPlan, TransitionType, WordTiming } from "./types.ts";

const MOTIONS: Motion[] = ["none", "push_in", "pull_out", "pan_left", "pan_right"];
const TRANSITIONS: TransitionType[] = ["cut", "fade"];

const text = (v: unknown): string => (typeof v === "string" ? v.trim() : "");
const list = (v: unknown): string[] =>
  Array.isArray(v) ? v.map(text).filter((s) => s.length > 0) : [];

/**
 * Turns whatever a model returned into a plan the rest of the pipeline can
 * trust, or says exactly why it cannot.
 *
 * The model's JSON is untrusted input. Fields it gets wrong in a harmless way
 * (an unknown camera move, a missing transition) are repaired and reported as
 * warnings; fields the pipeline cannot run without (no scenes, a scene that
 * shows nothing) are errors, and the caller retries the model with the issue
 * list instead of letting a half-plan crash a later stage.
 */
export function parseStoryPlan(raw: unknown): Parsed<StoryPlan> {
  const issues: Issue[] = [];
  const o = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!o) return { ok: false, issues: [{ path: "", message: "not an object", level: "error" }] };

  const scenesRaw = Array.isArray(o.scenes) ? o.scenes : [];
  if (scenesRaw.length === 0) {
    return { ok: false, issues: [{ path: "scenes", message: "no scenes", level: "error" }] };
  }

  const scenes: Scene[] = [];
  const seen = new Set<string>();
  scenesRaw.forEach((entry, i) => {
    const s = entry && typeof entry === "object" ? (entry as Record<string, unknown>) : {};
    const at = `scenes[${i}]`;

    const imagePrompt = text(s.imagePrompt) || text(s.visual);
    if (!imagePrompt) {
      issues.push({ path: `${at}.imagePrompt`, message: "scene shows nothing", level: "error" });
      return;
    }

    let id = text(s.id) || `s${i + 1}`;
    if (seen.has(id)) {
      issues.push({ path: `${at}.id`, message: `duplicate id "${id}", renamed`, level: "warning" });
      id = `${id}_${i + 1}`;
    }
    seen.add(id);

    let motion = text(s.motion) as Motion;
    if (!MOTIONS.includes(motion)) {
      if (motion) issues.push({ path: `${at}.motion`, message: `unknown motion "${motion}", using push_in`, level: "warning" });
      motion = "push_in";
    }
    let transition = text(s.transition) as TransitionType;
    if (!TRANSITIONS.includes(transition)) transition = "cut";

    const motionPrompt = text(s.motionPrompt);
    if (!motionPrompt) {
      issues.push({ path: `${at}.motionPrompt`, message: "no motion instruction, derived from camera move", level: "warning" });
    }

    scenes.push({
      id,
      order: i,
      narration: text(s.narration),
      visual: text(s.visual) || imagePrompt,
      imagePrompt,
      motionPrompt: motionPrompt || defaultMotionPrompt(motion),
      motion,
      transition,
      characters: list(s.characters),
      location: text(s.location) || null,
      emphasis: list(s.emphasis),
      sfx: list(s.sfx),
      durationS: typeof s.durationS === "number" && s.durationS > 0 ? s.durationS : null,
    });
  });

  if (scenes.length === 0) return { ok: false, issues };

  const characters = describedList(o.characters);
  const locations = describedList(o.locations);
  // A scene that names someone the plan never described will get a different
  // face every time -- say so rather than ship it.
  for (const scene of scenes) {
    for (const name of scene.characters) {
      if (!characters.some((c) => c.name.toLowerCase() === name.toLowerCase())) {
        issues.push({
          path: `scenes[${scene.order}].characters`,
          message: `"${name}" has no description in the plan's characters`,
          level: "warning",
        });
      }
    }
  }

  const script = text(o.script) || scenes.map((s) => s.narration).filter(Boolean).join(" ");
  return {
    ok: true,
    issues,
    value: {
      title: text(o.title) || "Untitled",
      hook: text(o.hook) || (scenes[0]?.narration ?? ""),
      script,
      characters,
      locations,
      musicBrief: text(o.musicBrief),
      scenes,
    },
  };
}

function describedList(v: unknown): Array<{ name: string; description: string }> {
  if (!Array.isArray(v)) return [];
  const out: Array<{ name: string; description: string }> = [];
  for (const e of v) {
    const o = e && typeof e === "object" ? (e as Record<string, unknown>) : {};
    const name = text(o.name);
    const description = text(o.description);
    if (name && description) out.push({ name, description });
  }
  return out;
}

function defaultMotionPrompt(m: Motion): string {
  switch (m) {
    case "push_in": return "Slow push-in toward the subject; the subject stays still and keeps its appearance.";
    case "pull_out": return "Slow pull-back revealing the surroundings; the subject keeps its appearance.";
    case "pan_left": return "Gentle pan to the left; nothing else changes.";
    case "pan_right": return "Gentle pan to the right; nothing else changes.";
    default: return "Locked camera; only small natural movement in the scene.";
  }
}

const tokens = (s: string): string[] => s.split(/\s+/).map(normalize).filter(Boolean);
const normalize = (w: string): string => w.toLowerCase().replace(/[^\p{L}\p{N}']/gu, "");

/**
 * Gives every scene its real duration from the real voice.
 *
 * Words are consumed in order: a scene owns as many spoken words as its
 * narration has, and runs from its first word's start to the next scene's
 * first word. Scenes with no narration take the gap they sit in. If the
 * voice spoke a different number of words than the script (the provider read
 * "$5" as "five dollars"), the scene starts are matched by position
 * proportion rather than shifted word by word, and a warning says so.
 */
export function timeScenesToVoice(
  plan: StoryPlan,
  words: WordTiming[],
  opts: { tailS?: number; leadS?: number } = {},
): { plan: StoryPlan; totalS: number; issues: Issue[] } {
  const issues: Issue[] = [];
  const tail = opts.tailS ?? 0.6;
  const lead = opts.leadS ?? 0;
  if (words.length === 0) {
    return { plan, totalS: 0, issues: [{ path: "words", message: "no word timings", level: "error" }] };
  }

  const wanted = plan.scenes.map((s) => tokens(s.narration).length);
  const totalWanted = wanted.reduce((a, b) => a + b, 0);
  if (totalWanted !== words.length) {
    issues.push({
      path: "words",
      message: `script has ${totalWanted} words but the voice has ${words.length}; scene starts matched by proportion`,
      level: "warning",
    });
  }

  // Index of the first word each scene owns.
  const firstWord: number[] = [];
  let used = 0;
  for (const n of wanted) {
    firstWord.push(totalWanted === words.length ? used : Math.round((used / Math.max(totalWanted, 1)) * words.length));
    used += n;
  }

  const at = (index: number) => words[Math.min(Math.max(index, 0), words.length - 1)]!;
  // When a scene's voice ends, so a silent scene after it can start there.
  const voiceEndOf: number[] = plan.scenes.map((_, i) =>
    wanted[i] === 0 ? Number.NaN : at(firstWord[i]! + wanted[i]! - 1).endS
  );
  const starts: number[] = [];
  let cursor = 0;
  for (let i = 0; i < plan.scenes.length; i++) {
    if (wanted[i] === 0) {
      starts.push(cursor);
    } else {
      starts.push(at(firstWord[i]!).startS);
      cursor = voiceEndOf[i]!;
    }
  }
  starts[0] = Math.min(starts[0]!, lead);

  const voiceEnd = words[words.length - 1]!.endS;
  const totalS = round(voiceEnd + tail);
  const scenes = plan.scenes.map((scene, i) => {
    const from = i === 0 ? 0 : starts[i]!;
    const to = i === plan.scenes.length - 1 ? totalS : Math.max(starts[i + 1]!, from);
    return { ...scene, durationS: round(to - from) };
  });

  for (const s of scenes) {
    if ((s.durationS ?? 0) <= 0) {
      issues.push({ path: `scenes[${s.order}]`, message: "scene has no time after fitting to the voice", level: "error" });
    }
  }
  return { plan: { ...plan, scenes }, totalS, issues };
}

/** A scene longer than one request can make becomes several shots. */
export interface Shot {
  id: string;
  sceneId: string;
  /** 0 is the approved still animated as-is; later parts continue the scene
   *  from the same reference so the subject does not change. */
  part: number;
  durationS: number;
}

export function splitIntoShots(plan: StoryPlan, limits: ClipLimits): { shots: Shot[]; issues: Issue[] } {
  const shots: Shot[] = [];
  const issues: Issue[] = [];
  for (const scene of plan.scenes) {
    const total = scene.durationS ?? 0;
    if (total <= 0) {
      issues.push({ path: `scenes[${scene.order}]`, message: "no duration", level: "error" });
      continue;
    }
    const parts = Math.max(1, Math.ceil(total / limits.maxS));
    const each = round(total / parts);
    if (each < limits.minS) {
      issues.push({
        path: `scenes[${scene.order}]`,
        message: `${each}s is below the model's ${limits.minS}s minimum; the clip will be trimmed`,
        level: "warning",
      });
    }
    for (let p = 0; p < parts; p++) {
      const d = p === parts - 1 ? round(total - each * (parts - 1)) : each;
      shots.push({ id: `${scene.id}-${p}`, sceneId: scene.id, part: p, durationS: d });
    }
  }
  return { shots, issues };
}

/** Plan-level checks that hold regardless of model: coverage of the target
 *  length and a hook that arrives inside the first seconds. */
export function checkCoverage(plan: StoryPlan, targetS: number, toleranceS = 3): Issue[] {
  const issues: Issue[] = [];
  const total = plan.scenes.reduce((a, s) => a + (s.durationS ?? 0), 0);
  if (Math.abs(total - targetS) > toleranceS) {
    issues.push({
      path: "scenes",
      message: `scenes add up to ${round(total)}s but ${targetS}s was asked for`,
      level: "warning",
    });
  }
  const first = plan.scenes[0]?.durationS ?? 0;
  if (first > 6) {
    issues.push({ path: "scenes[0]", message: `the opening scene runs ${first}s; a hook should land within about 3s`, level: "warning" });
  }
  return issues;
}

const round = (n: number): number => Math.round(n * 100) / 100;
