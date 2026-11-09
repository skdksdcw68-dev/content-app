/**
 * The code-drawn formats (Stickman Showdown, Glow Explainer) as a job.
 *
 * They ride the story job: an `agent_runs` row of kind "story" whose style row
 * says `workflow.engine = "drawn"`. Instead of pictures, the writer plans what
 * to show, the voice is recorded (Glow only), and the Fly renderer DRAWS the
 * video from the plan (renderer/draw). So a clip costs the writer, the voice
 * and a few minutes of render time. State lives in `input.drawn`; one call is
 * one tick, like the story.
 */
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import {
  GLOW_WRITER_PROMPT,
  SHOWDOWN_WRITER_PROMPT,
  glowScript,
  parseGlowPlan,
  parseShowdownBrief,
  planShowdown,
  wordsOf,
} from "../_shared/video/drawn.ts";
import type { GlowPlan, ShowdownPlan } from "../_shared/video/drawn.ts";
import { extractJson } from "../_shared/video/planner.ts";
import type { RenderSpec, StoryRequest } from "../_shared/video/story.ts";
import type { WordTiming } from "../_shared/video/types.ts";
import { MODELS } from "../_shared/route.ts";
import { recordUsage } from "../_shared/usage.ts";
import { write } from "../_shared/writer.ts";
import { depsFor } from "./story.ts";
import type { Run, Tell } from "./story.ts";

export type DrawnKind = "showdown" | "glow";

interface Music { path: string; startS: number; gainDb?: number; beatS?: number; delayS?: number }

interface DrawnState {
  phase: "plan" | "voice" | "render" | "finish" | "done" | "failed";
  kind: DrawnKind;
  request: StoryRequest;
  title?: string;
  caption?: string;
  plan?: ShowdownPlan | GlowPlan;
  words?: WordTiming[];
  voicePath?: string;
  durationS?: number;
  music?: Music | null;
  renderJobId?: string;
  renderTries: number;
  finalPath?: string;
  warnings: string[];
  error?: string;
}

/** Words the narrator speaks per second, the pace the Glow writer is told. */
const WORDS_PER_S = 2.8;
const MAX_RENDER_TRIES = 2;

/** Which drawn engine a style uses, or null for a picture story. */
export async function drawnKindFor(admin: SupabaseClient, slug: string | undefined): Promise<DrawnKind | null> {
  if (!slug) return null;
  const { data } = await admin.from("content_templates").select("workflow").eq("slug", slug).maybeSingle();
  const w = (data as { workflow?: { engine?: string; drawn?: string } } | null)?.workflow;
  return w?.engine === "drawn" && (w.drawn === "showdown" || w.drawn === "glow") ? w.drawn : null;
}

export async function drawnStep(admin: SupabaseClient, run: Run, tell: Tell, kind: DrawnKind): Promise<string> {
  const request = run.input.request as StoryRequest;
  let state = (run.input.drawn as DrawnState | undefined) ?? { phase: "plan", kind, request, renderTries: 0, warnings: [] } satisfies DrawnState;
  const deps = depsFor(admin, run, tell);
  // The script is the product, so it is written by the strong model (tested 8 Nov
  // 2026: gpt-5.6-terra kept the asked length, varied the scenes and wrote
  // about 4 cents a script; gpt-4.1 repeated scene kinds and ran short).
  const writer = async (system: string, user: string): Promise<string> => {
    const c = await write({ effort: "medium", openaiModel: MODELS.smart, maxTokens: 12000, messages: [{ role: "system", content: system }, { role: "user", content: user }] });
    await recordUsage(admin, { userId: run.user_id, brandId: run.brand_id, kind: "research", model: c.model, usage: c.usage });
    return c.choices?.[0]?.message?.content ?? "";
  };
  const persist = async (s: DrawnState) => {
    const { error } = await admin.from("agent_runs").update({ input: { ...run.input, drawn: s } }).eq("id", run.id);
    if (error) throw new Error(`could not save the video: ${error.message}`);
    run.input = { ...run.input, drawn: s };
  };
  const fail = async (message: string): Promise<string> => {
    state = { ...state, phase: "failed", error: message };
    await persist(state);
    await admin.rpc("finish_agent_run", { p_run: run.id, p_status: "failed", p_error: message.slice(0, 300) });
    return "failed";
  };
  const began = Date.now();

  // Several phases can follow each other in one call; stop starting new ones
  // after 55 s (the run's lease is two minutes).
  for (;;) {
    switch (state.phase) {
      case "plan": {
        await deps.say(kind === "glow" ? "Writing the script and planning the scenes" : "Choosing the words for the showdown");
        const topic = request.topic;
        const about = [request.brandContext ? `About the person: ${request.brandContext}` : "", request.direction ? `Direction: ${request.direction}` : ""].filter(Boolean).join("\n");
        if (kind === "showdown") {
          let brief = null;
          let notes = "";
          for (let attempt = 0; attempt < 2 && !brief; attempt++) {
            const reply = await writer(SHOWDOWN_WRITER_PROMPT, `Topic or theme: ${topic}\n${about}${notes}`);
            const parsed = parseShowdownBrief(extractJson(reply));
            if (parsed.ok) brief = parsed.value;
            else notes = `\n\nYour last answer was refused: ${parsed.issues.map((i) => `${i.path}: ${i.message}`).join("; ")}. Answer again with valid JSON.`;
          }
          if (!brief) return await fail("The writer did not come back with a usable showdown. Nothing was charged.");
          // The length they asked for (10 to 30 s): the drop is placed so the
          // video ends about 6.4 s after it. Nothing asked: the music decides.
          const asked = typeof request.durationS === "number" ? Math.min(30, Math.max(10, request.durationS)) : null;
          const music = await pickMusic(admin, "showdown", asked !== null ? Math.min(23.6, Math.max(4, asked - 6.4)) : null);
          const plan = planShowdown(brief, music?.beatS ?? 13.6);
          state = { ...state, phase: "render", title: brief.title, caption: brief.caption, plan, durationS: plan.durationS, music };
          if (!music) state.warnings.push("no music was added");
        } else {
          const seconds = Math.min(900, Math.max(30, request.durationS ?? 70));
          const target = Math.round(seconds * WORDS_PER_S);
          let plan: GlowPlan | null = null;
          let notes = "";
          for (let attempt = 0; attempt < 2 && !plan; attempt++) {
            const reply = await writer(GLOW_WRITER_PROMPT, `Idea or topic: ${topic}\n${about}\nLength: about ${seconds} seconds, so about ${target} words of narration in total.${notes}`);
            const parsed = parseGlowPlan(extractJson(reply));
            if (parsed.ok) {
              plan = parsed.value;
              state.warnings.push(...parsed.issues.map((i) => `${i.path}: ${i.message}`).slice(0, 5));
            } else notes = `\n\nYour last answer was refused: ${parsed.issues.map((i) => `${i.path}: ${i.message}`).join("; ")}. Answer again with valid JSON.`;
          }
          if (!plan) return await fail("The writer did not come back with a usable script. Nothing was charged.");
          const count = wordsOf(glowScript(plan)).length;
          if (count < target * 0.6 || count > target * 1.5) state.warnings.push(`the script is ${count} words; about ${target} were asked for`);
          state = { ...state, phase: "voice", title: plan.title, caption: plan.caption, plan, music: await pickMusic(admin, "glow") };
        }
        await persist(state);
        break;
      }

      case "voice": {
        await deps.say("Recording the voiceover");
        const spoken = await deps.speak(glowScript(state.plan as GlowPlan));
        if (spoken.problem || spoken.words.length === 0) return await fail(`The voiceover could not be made: ${spoken.problem ?? "no word timing came back"}.`);
        const voicePath = `${run.user_id}/${run.id}/voice.mp3`;
        await deps.store.put(voicePath, spoken.audio, spoken.mime);
        state = { ...state, phase: "render", voicePath, words: spoken.words, durationS: spoken.words[spoken.words.length - 1]!.endS + 1.6 };
        await persist(state);
        break;
      }

      case "render": {
        if (!state.renderJobId) {
          await deps.say("Drawing the video");
          const glow = kind === "glow";
          const spec: RenderSpec = {
            aspect: glow ? "16:9" : "9:16",
            fps: glow ? 30 : 60,
            durationS: state.durationS ?? 20,
            scenes: [],
            voice: state.voicePath ? { path: state.voicePath, startS: 0 } : null,
            words: state.words ?? [],
            emphasis: [],
            captions: false,
            captionTheme: "clean",
            musicBrief: null,
            outputPath: `${run.user_id}/${run.id}/final.mp4`,
            drawn: { kind, plan: state.plan, ...(state.music ? { music: { path: state.music.path, startS: state.music.startS, gainDb: state.music.gainDb, delayS: state.music.delayS } } : {}) },
          };
          state = { ...state, renderJobId: await deps.queueRender(spec) };
          await persist(state);
        }
        const status = await deps.renderStatus(state.renderJobId!);
        if (status.status === "done" && status.outputPath) {
          state = { ...state, phase: "finish", finalPath: status.outputPath };
          await persist(state);
          break;
        }
        if (status.status === "failed") {
          // One more try before giving up: a render can die on a hiccup.
          if (state.renderTries + 1 < MAX_RENDER_TRIES) {
            state = { ...state, renderJobId: undefined, renderTries: state.renderTries + 1 };
            state.warnings.push(`the first render failed (${(status.error ?? "unknown").slice(0, 80)}); tried again`);
            await persist(state);
            break;
          }
          return await fail(status.error ?? "The video could not be drawn.");
        }
        await persist(state);
        await admin.rpc("advance_agent_run", { p_run: run.id, p_step: "render", p_detail: "Drawing the video", p_after: "15 seconds" });
        return "render";
      }

      case "finish": {
        const glow = kind === "glow";
        const { data: made } = await admin.rpc("create_artifact", {
          p_user: run.user_id,
          p_kind: "video",
          p_title: state.title ?? "Video",
          p_body: { prompt: request.topic, model_label: "Postpilot drawn video", seconds: state.durationS, aspect: glow ? "16:9" : "9:16", scenes: 0, warnings: state.warnings, caption: state.caption ?? "" },
          p_thread: run.thread_id,
          p_run: run.id,
          p_parent: null,
          p_status: "pending",
        });
        const artifactId = made as string;
        const dir = state.finalPath!.split("/").slice(0, -1).join("/");
        const { data: info } = await admin.storage.from("artifacts").list(dir, { search: "final.mp4" });
        const size = (info?.[0]?.metadata as { size?: number } | undefined)?.size ?? 0;
        await admin.rpc("attach_artifact_file", { p_artifact: artifactId, p_path: state.finalPath, p_mime: "video/mp4", p_size: size });
        const frame = glow ? { width: 1920, height: 1080 } : { width: 1080, height: 1920 };
        await tell(`🎬 Your video is ready: “${state.title}”, ${Math.round(state.durationS ?? 0)} seconds.${state.caption ? `\n\nCaption: ${state.caption}` : ""}`, {
          kind: "artifact", artifact_id: artifactId, artifact_kind: "video", width: frame.width, height: frame.height,
        });
        state = { ...state, phase: "done" };
        await persist(state);
        await admin.rpc("finish_agent_run", { p_run: run.id, p_status: "succeeded", p_result: { final: state.finalPath } });
        return "done";
      }

      default:
        return state.phase;
    }
    if (Date.now() - began > 55_000) {
      await admin.rpc("advance_agent_run", { p_run: run.id, p_step: state.phase, p_detail: "Working", p_after: "5 seconds" });
      return state.phase;
    }
  }
}

/** A track from the music library for this format, or null when there is none
 *  (the video then has no music and says so). The library is `drawn_music`
 *  (migration 0106): royalty-free tracks with their drop measured in advance. */
async function pickMusic(admin: SupabaseClient, kind: DrawnKind, wantBeat: number | null = null): Promise<Music | null> {
  const { data } = await admin.from("drawn_music").select("path, drop_s, gain_db, start_s").eq("enabled", true).contains("formats", [kind]).limit(20);
  const rows = (data ?? []) as Array<{ path: string; drop_s: number | null; gain_db: number | null; start_s: number | null }>;
  if (rows.length === 0) return null;
  const row = rows[Math.floor(Math.random() * rows.length)]!;
  if (kind === "showdown") {
    // Start the track so its drop lands on the beat the plan uses (13.6 s);
    // a track whose drop comes earlier sets the beat instead.
    const drop = row.drop_s ?? 13.6;
    if (wantBeat !== null) {
      // A longer video than the track's own lead-in: start the track late, so
      // the build-up is silence and the thuds of the figures falling, and the
      // drop still lands on the beat.
      return drop >= wantBeat
        ? { path: row.path, startS: drop - wantBeat, gainDb: row.gain_db ?? -1, beatS: wantBeat }
        : { path: row.path, startS: 0, gainDb: row.gain_db ?? -1, beatS: wantBeat, delayS: wantBeat - drop };
    }
    const beat = Math.min(13.6, Math.max(6, drop));
    return { path: row.path, startS: Math.max(0, drop - beat), gainDb: row.gain_db ?? -1, beatS: beat };
  }
  return { path: row.path, startS: row.start_s ?? 0, gainDb: row.gain_db ?? -18 };
}
