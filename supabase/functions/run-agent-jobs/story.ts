/**
 * The story job, wired to the real world.
 *
 * `_shared/video/story.ts` is the state machine and knows no provider; this is
 * the one place that does. A story is an `agent_runs` row of kind "story": its
 * state lives in `input.story`, one call to `storyStep` is one tick, and the
 * conversation sees each step as a message while the app's live card sees it as
 * an `agent_events` row.
 */
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { NothingCanDoThis, routePoll, routeSubmit } from "../_shared/connectors/route.ts";
import type { Submitted } from "../_shared/connectors/contract.ts";
import { chargeForGeneration, refundCredits, settleCredits } from "../_shared/credits.ts";
import { PublicError } from "../_shared/http.ts";
import { wakeRenderer } from "../_shared/render-wake.ts";
import { imageSize } from "../_shared/media.ts";
import { recordUsage } from "../_shared/usage.ts";
import { write } from "../_shared/writer.ts";
import { newStory, stepStory, type ImagePoll, type StoryDeps, type StoryRequest, type StoryState } from "../_shared/video/story.ts";
import { parseReview } from "../_shared/video/review.ts";
import { extractJson } from "../_shared/video/planner.ts";
import { speak, VoiceError } from "../_shared/video/voice.ts";

export interface Run {
  id: string;
  user_id: string;
  thread_id: string | null;
  brand_id: string | null;
  input: Record<string, unknown>;
  attempts: number;
}

export type Tell = (text: string, hint?: Record<string, unknown> | null) => Promise<void>;

const BUCKET = "artifacts";
/** What a house image costs us, used only to keep the per-story budget honest
 *  before the provider says what it really charged. */
const IMAGE_ESTIMATE_USD = 0.07;

export async function storyStep(admin: SupabaseClient, run: Run, tell: Tell): Promise<string> {
  const saved = run.input.story as StoryState | undefined;
  const state: StoryState = saved ?? newStory(run.input.request as StoryRequest);
  const deps = depsFor(admin, run, tell);

  // Keep stepping inside this one invocation instead of going back to sleep
  // until the next cron minute: a story is mostly waiting on pictures, and a
  // step per minute made a 20-second story take ten minutes. The run's lease is
  // two minutes and one step can take 30 s, so stop starting steps after 55 s;
  // whatever is left waits for the next tick exactly as before.
  const began = Date.now();
  let result = await stepStory(deps, state);
  while (!result.done && result.waitS <= 12 && Date.now() - began < 55_000) {
    await persist(admin, run, result.state);
    await new Promise((resolve) => setTimeout(resolve, Math.min(result.waitS, 8) * 1000));
    result = await stepStory(deps, result.state);
  }
  const after = result.state;
  // One write for whatever the step changed; `save` inside the machine has
  // already checkpointed anything that cost money.
  await persist(admin, run, after);

  if (result.done) {
    if (after.phase === "done") {
      await admin.rpc("finish_agent_run", { p_run: run.id, p_status: "succeeded", p_result: { final: after.finalPath, spent_usd: after.spentUsd } });
      return "done";
    }
    await admin.rpc("finish_agent_run", { p_run: run.id, p_status: "failed", p_error: (after.error ?? "story failed").slice(0, 300) });
    return "failed";
  }

  await admin.rpc("advance_agent_run", {
    p_run: run.id,
    p_step: after.phase,
    p_detail: labelFor(after),
    p_after: `${Math.max(1, Math.round(result.waitS))} seconds`,
  });
  return after.phase;
}

function labelFor(s: StoryState): string {
  const scenes = Object.values(s.scenes);
  switch (s.phase) {
    case "plan": return "Planning the story";
    case "voice": return "Recording the voiceover";
    case "images": {
      const done = scenes.filter((x) => x.status === "passed" || x.status === "accepted").length;
      return `Pictures ${done} of ${scenes.length} done`;
    }
    case "render": return "Putting the video together";
    default: return "Finishing";
  }
}

async function persist(admin: SupabaseClient, run: Run, state: StoryState): Promise<void> {
  const { error } = await admin.from("agent_runs").update({ input: { ...run.input, story: state } }).eq("id", run.id);
  if (error) throw new Error(`could not save the story: ${error.message}`);
  run.input = { ...run.input, story: state };
}

/** Signed links to the reference frames a style keeps in storage, if any. */
async function styleReferences(admin: SupabaseClient, slug: string | undefined): Promise<Array<{ url: string; kind: "image" }>> {
  if (!slug || !/^[a-z0-9_-]+$/.test(slug)) return [];
  const { data: files } = await admin.storage.from(BUCKET).list(`refs/${slug}`, { limit: 4 });
  const out: Array<{ url: string; kind: "image" }> = [];
  for (const f of files ?? []) {
    if (!/.(jpe?g|png|webp)$/i.test(f.name)) continue;
    const { data } = await admin.storage.from(BUCKET).createSignedUrl(`refs/${slug}/${f.name}`, 3600);
    if (data?.signedUrl) out.push({ url: data.signedUrl, kind: "image" });
  }
  return out;
}

export function depsFor(admin: SupabaseClient, run: Run, tell: Tell): StoryDeps {
  const userId = run.user_id;
  const ask = async (system: string, user: string): Promise<string> => {
    const c = await write({
      effort: "medium",
      openaiModel: "gpt-4.1",
      maxTokens: 12000,
      messages: [{ role: "system", content: system }, { role: "user", content: user }],
    });
    await recordUsage(admin, { userId, brandId: run.brand_id, kind: "research", model: c.model, usage: c.usage });
    return c.choices?.[0]?.message?.content ?? "";
  };

  return {
    userId,
    runId: run.id,

    async style(slug) {
      const { data } = await admin.from("content_templates").select("slug, name, visual_style, workflow").eq("slug", slug).maybeSingle();
      return (data as never) ?? null;
    },

    ask,

    async speak(text) {
      const key = Deno.env.get("ELEVENLABS_API_KEY");
      // The voice picked on the card, else the server's default narrator.
      const chosen = (run.input.request as StoryRequest | undefined)?.voiceId
        ?? (run.input.story as StoryState | undefined)?.request?.voiceId;
      const voiceId = chosen && /^[A-Za-z0-9]{10,40}$/.test(chosen) ? chosen : Deno.env.get("ELEVENLABS_VOICE_ID");
      if (!key || !voiceId) throw new PublicError("The voiceover isn't set up on the server yet.", 503, false);
      try {
        return await speak({ apiKey: key, voiceId, text, model: Deno.env.get("ELEVENLABS_MODEL") ?? "eleven_multilingual_v2" });
      } catch (thrown) {
        // A rate limit is another try of the same step; anything else is final
        // and the machine will say so.
        if (thrown instanceof VoiceError && !thrown.retryable) {
          return { audio: new Uint8Array(), mime: "audio/mpeg", words: [], durationS: null, characters: text.length, problem: thrown.message.slice(0, 120) };
        }
        throw thrown;
      }
    },

    image: {
      async submit(prompt, o) {
        // A style can carry reference frames (storage artifacts/refs/<slug>/):
        // they go to the image model with every picture so the look holds, as
        // the 3D stories need (5 Nov 2026: the look only matched with them).
        const references = await styleReferences(admin, (run.input.request as { styleSlug?: string } | undefined)?.styleSlug);
        // On our money the credits are taken now, per picture, and given back
        // if the picture never arrives.
        let charge = null;
        try {
          charge = await chargeForGeneration(admin, userId, { capability: "image_generation", prompt, settings: {} });
        } catch (thrown) {
          if (thrown instanceof PublicError && thrown.status === 402) {
            await tell(thrown.message);
          }
          throw thrown;
        }
        try {
          const routed = await routeSubmit(admin, {
            userId,
            capability: "image_generation",
            prompt,
            options: { aspect_ratio: o.aspect },
            ...(references.length > 0 ? { references } : {}),
          });
          return {
            handle: { submitted: routed.submitted, connectionId: routed.connectionId, creditRef: charge?.ref ?? null, credits: charge?.credits ?? null },
            costUsd: IMAGE_ESTIMATE_USD,
          };
        } catch (thrown) {
          if (charge) await refundCredits(admin, userId, charge.ref);
          if (thrown instanceof NothingCanDoThis) throw new PublicError(`No picture model could make that (${thrown.code}).`, 502, false);
          throw thrown;
        }
      },

      async poll(raw): Promise<ImagePoll> {
        const h = raw as { submitted: Submitted; connectionId: string; creditRef: string | null; credits: number | null };
        let url = h.submitted.state === "done" ? h.submitted.outputUrl ?? null : null;
        let mime: string | undefined;
        if (!url) {
          const polled = await routePoll(admin, {
            connectionId: h.connectionId,
            ref: h.submitted.ref,
            statusUrl: h.submitted.statusUrl ?? "",
            capability: "image_generation",
          });
          if (polled.status === "failed" || polled.status === "nsfw") {
            if (h.creditRef) await refundCredits(admin, userId, h.creditRef);
            return {
              state: "failed",
              error: polled.status === "nsfw" ? "the picture model refused that scene" : (polled.error ?? "the picture model failed").slice(0, 160),
              // A refusal repeated unchanged is the same refusal.
              retryable: polled.status !== "nsfw" && polled.code !== "refused",
            };
          }
          if (polled.status !== "completed" || !polled.videoUrl) return { state: "running" };
          url = polled.videoUrl;
          mime = polled.mime;
        }
        const res = await fetch(url);
        if (!res.ok) throw new Error(`download ${res.status}`);
        const bytes = new Uint8Array(await res.arrayBuffer());
        await settleCredits(admin, userId, h.creditRef, h.credits, h.submitted.charged);
        return { state: "done", bytes, mime: mime ?? res.headers.get("content-type") ?? "image/png" };
      },
    },

    async review({ imageUrl, scene, plan, production }) {
      const who = scene.characters
        .map((n) => plan.characters.find((c) => c.name.toLowerCase() === n.toLowerCase()))
        .filter(Boolean)
        .map((c) => `${c!.name}: ${c!.description}`)
        .join("; ");
      const completion = await write({
        effort: "low",
        openaiModel: "gpt-4.1-mini",
        json: true,
        maxTokens: 1500,
        messages: [
          {
            role: "system",
            content: [
              // 31 Oct 2026: the first real story redid 3 of its 6 pictures,
              // a third of what it cost, for "the hangers appear static" (a
              // still never moves; the camera move comes later), "not fully
              // 9:16" (the request sets the size, not the picture) and "the
              // shadows could be deeper". A redo is for a picture that would
              // look WRONG in the video, nothing less.
              "You check pictures that will become the stills of a short vertical video. You did not make this picture.",
              "Judge ONLY what you can see. Return one JSON object:",
              '{"verdict":"PASS|RETRY|ESCALATE","score":0..1,"problems":[string],"correction":string|null}',
              "RETRY only for a fault a viewer would notice: the wrong or missing subject, deformed hands/faces/limbs, readable text, logos or watermarks, the main subject badly cut off, a character who plainly contradicts the description, or a picture clearly not in the asked style (a photo when a drawing was asked, colour when monochrome was asked).",
              "Do NOT retry for: no visible movement (it is a still; motion is added later), the picture's size or aspect ratio (that is fixed elsewhere), mood or lighting that is close enough, or small details of the scene. Those are a PASS.",
              "When in doubt, PASS. Every redo costs money.",
              "RETRY with a `correction` written as an instruction for the picture prompt. ESCALATE only if the scene itself cannot be drawn as described.",
              "A PASS must have an empty problems list.",
            ].join("\n"),
          },
          {
            role: "user",
            content: [
              {
                type: "text",
                text: `Scene: ${scene.visual}\nIntended picture: ${scene.imagePrompt}\n${who ? `Characters: ${who}\n` : ""}Style: ${production.visualStyle || "cinematic"}`,
              },
              { type: "image_url", image_url: { url: imageUrl } },
            ],
          },
        ],
      });
      await recordUsage(admin, { userId, brandId: run.brand_id, kind: "research", model: completion.model, usage: completion.usage });
      const reply = completion.choices?.[0]?.message?.content ?? "";
      // An unreadable answer is an ESCALATE: silence never approves a picture.
      return { review: parseReview(extractJson(reply)), costUsd: 0.01 };
    },

    imageSize,

    store: {
      async put(path, bytes, mime) {
        const { error } = await admin.storage.from(BUCKET).upload(path, bytes, { contentType: mime, upsert: true });
        if (error) throw new Error(`upload: ${error.message}`);
      },
      async signedUrl(path) {
        const { data, error } = await admin.storage.from(BUCKET).createSignedUrl(path, 3600);
        if (error || !data) throw new Error(`sign: ${error?.message ?? "no url"}`);
        return data.signedUrl;
      },
    },

    // Steps are marked so the app folds a story's whole progress into one
    // block, instead of a message per picture each with its own buttons
    // (Netro, 31 Oct 2026, with a screenshot of a dozen of them).
    say: (text) => tell(text, { kind: "progress", run_id: run.id }),
    sayOutcome: (text) => tell(text),

    async save(state) {
      await persist(admin, run, state);
    },

    async queueRender(spec) {
      // One live render per run (a unique index says so): asking twice returns
      // the first, so a retried step cannot start a second render.
      const { data: existing } = await admin.from("render_jobs").select("id").eq("run_id", run.id).in("status", ["queued", "rendering", "done"]).maybeSingle();
      if (existing) return (existing as { id: string }).id;
      const { data, error } = await admin.from("render_jobs").insert({ run_id: run.id, user_id: userId, spec }).select("id").single();
      if (error || !data) throw new Error(`render job: ${error?.message ?? "not created"}`);
      // The renderer sleeps while there is nothing to render.
      await wakeRenderer();
      return (data as { id: string }).id;
    },

    async renderStatus(id) {
      const { data } = await admin.from("render_jobs").select("status, output_path, error, qc, attempts, lease_until, created_at").eq("id", id).maybeSingle();
      const row = data as { status: string; output_path: string | null; error: string | null; qc: never; attempts: number; lease_until: string | null; created_at: string } | null;
      if (!row) return { status: "failed", error: "the render job disappeared" };
      // A render that stopped for good must say so. One stuck "rendering" for
      // hours (7 Nov 2026) had its lease expire and nothing ever woke the
      // renderer, because only "queued" jobs were nudged; and a job out of its
      // three tries (claim_render_job) was never marked failed. The lease is
      // the renderer's own deadline (15 minutes), so past it the job is dead.
      const leaseRanOut = row.status === "rendering" && row.lease_until !== null && new Date(row.lease_until).getTime() < Date.now();
      const waitedTooLong = row.status === "queued" && Date.now() - new Date(row.created_at).getTime() > 45 * 60_000;
      // Woken and still nobody took it back in half an hour: the wake-up does
      // not work, and waiting longer will not change that.
      const leaseLongGone = leaseRanOut && Date.now() - new Date(row.lease_until as string).getTime() > 30 * 60_000;
      if ((leaseRanOut && row.attempts >= 3) || leaseLongGone || waitedTooLong) {
        const error = waitedTooLong
          ? "The video renderer did not start. Nothing was published."
          : "The video renderer did not finish. Nothing was published.";
        await admin.rpc("finish_render_job", { p_job: id, p_ok: false, p_path: null, p_qc: null, p_error: error });
        return { status: "failed", error };
      }
      // Still waiting: the renderer may have stopped in the moment between its
      // last empty look at the queue and this job arriving. Starting it again
      // is a no-op when it is already running. A render whose time ran out
      // (and has tries left) is claimed again by the renderer once it is awake.
      if (row.status === "queued" || leaseRanOut) await wakeRenderer();
      return {
        status: row.status === "cancelled" ? "failed" : (row.status as "queued" | "rendering" | "done" | "failed"),
        ...(row.output_path ? { outputPath: row.output_path } : {}),
        ...(row.error ? { error: row.error } : {}),
        ...(row.qc ? { qc: row.qc } : {}),
      };
    },

    async publish({ finalPath, plan, warnings, durationS, production }) {
      const { data: made } = await admin.rpc("create_artifact", {
        p_user: userId,
        p_kind: "video",
        p_title: plan.title,
        p_body: {
          prompt: plan.hook,
          model_label: "Postpilot story",
          seconds: durationS,
          aspect: production.aspect,
          scenes: plan.scenes.length,
          warnings,
        },
        p_thread: run.thread_id,
        p_run: run.id,
        p_parent: null,
        p_status: "pending",
      });
      const artifactId = made as string;
      // The file is already in storage where the worker put it; the artifact
      // points at it rather than copying a video around.
      const { data: info } = await admin.storage.from(BUCKET).list(finalPath.split("/").slice(0, -1).join("/"), { search: "final.mp4" });
      const size = (info?.[0]?.metadata as { size?: number } | undefined)?.size ?? 0;
      await admin.rpc("attach_artifact_file", { p_artifact: artifactId, p_path: finalPath, p_mime: "video/mp4", p_size: size });
      const frame = production.aspect === "9:16" ? { width: 1080, height: 1920 } : production.aspect === "16:9" ? { width: 1920, height: 1080 } : { width: 1080, height: 1080 };
      const caveat = warnings.length ? `\n\nNotes: ${warnings.slice(0, 3).join(" · ")}` : "";
      await tell(`🎬 Your video is ready: “${plan.title}”, ${Math.round(durationS)} seconds.${caveat}`, {
        kind: "artifact",
        artifact_id: artifactId,
        artifact_kind: "video",
        width: frame.width,
        height: frame.height,
      });
    },

    async assetRecord(a) {
      await admin.from("story_assets").insert({
        run_id: run.id, user_id: userId, scene_id: a.sceneId, kind: a.kind, version: a.attempt, path: a.path,
        cost_usd: a.costUsd, meta: a.meta ?? {},
      });
    },
  };
}
