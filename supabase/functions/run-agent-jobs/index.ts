/**
 * Carries long jobs forward, one step per tick.
 *
 * This is the worker, and it is not a container. The plan called for one on Fly
 * and that is still the right shape eventually -- but it costs money this
 * project does not have, and the thing it would do is already proven here:
 * pg_cron wakes an Edge Function, the function claims work with a lease, does
 * one step, and puts it back. `run-due-posts` and `poll-generations` have been
 * doing exactly that every minute for days.
 *
 * The shape that makes it work is one step per tick, never a loop until done. A
 * step that finishes inside the wall clock is a step that cannot be lost, and a
 * job that needs eleven of them takes eleven minutes rather than timing out at
 * 150 seconds having half-written something. The cost is latency; the return is
 * that closing the app changes nothing at all.
 *
 * Every step ends by writing where it got to, so a crash between two steps
 * resumes at the boundary rather than at the beginning. That is also what makes
 * the conversation reconstructable: `agent_events` is not a log of this
 * function, it is the record the app replays.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json } from "../_shared/http.ts";
import { MODELS } from "../_shared/route.ts";
import { NothingCanDoThis, routePoll, routeSubmit } from "../_shared/connectors/route.ts";
import type { Capability, Submitted } from "../_shared/connectors/contract.ts";
import { buildDocx, buildPdf, buildZip, type Document } from "../_shared/exports.ts";
import { inspect } from "../_shared/media.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");

/** Small, because each run may spend most of a minute thinking. Whatever is not
 *  taken this tick is taken next tick; the queue is durable. */
const BATCH = 2;

type Admin = ReturnType<typeof createClient>;

interface Run {
  id: string;
  user_id: string;
  thread_id: string | null;
  brand_id: string | null;
  kind: string;
  step: string;
  input: Record<string, unknown>;
  attempts: number;
}

Deno.serve(async (request) => {
  if (!CRON_SECRET || !timingSafeEqual(request.headers.get("x-cron-secret") ?? "", CRON_SECRET)) {
    return json({ error: "no" }, 401);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);

  const { data: due, error } = await admin.rpc("due_agent_runs", { p_limit: BATCH });
  if (error) {
    console.error("due_agent_runs", error);
    return json({ error: "claim failed" }, 500);
  }

  const runs = (due ?? []) as Run[];
  if (runs.length === 0) return json({ advanced: 0 });

  const results: Record<string, string> = {};

  for (const run of runs) {
    try {
      results[run.id] = await advance(admin, run);
    } catch (thrown) {
      console.error("run", run.id, thrown);
      const detail = thrown instanceof Error ? thrown.message : "step failed";

      // Six attempts is the ceiling `due_agent_runs` enforces. Below it the run
      // is put back with a delay rather than killed: most step failures are a
      // provider having a bad minute, and burying a half-finished research job
      // because one call timed out is worse than waiting two more minutes.
      if (run.attempts >= 5) {
        await admin.rpc("finish_agent_run", {
          p_run: run.id,
          p_status: "failed",
          p_error: detail,
        });
        results[run.id] = "failed";
      } else {
        await admin
          .from("agent_runs")
          .update({
            attempts: run.attempts + 1,
            run_after: new Date(Date.now() + 60_000).toISOString(),
            claimed_by: null,
            lease_until: null,
          })
          .eq("id", run.id);
        await admin.rpc("append_agent_event", {
          p_run: run.id,
          p_type: "error",
          p_payload: { detail, retrying: true },
        });
        results[run.id] = "retrying";
      }
    }
  }

  return json({ advanced: runs.length, results });
});

/**
 * One step of one run.
 *
 * Returns the step it moved to, so the tick's response says what actually
 * happened rather than "ok".
 */
async function advance(admin: Admin, run: Run): Promise<string> {
  // Held for two minutes so a second tick cannot take the same run while this
  // one is mid-call. `reap_leases` puts it back if this function dies.
  await admin
    .from("agent_runs")
    .update({
      claimed_by: `tick-${crypto.randomUUID().slice(0, 8)}`,
      lease_until: new Date(Date.now() + 120_000).toISOString(),
      status: "running",
    })
    .eq("id", run.id);

  if (run.kind === "research") return await researchStep(admin, run);
  if (run.kind === "export") return await exportStep(admin, run);
  if (run.kind === "generate") return await generateStep(admin, run);

  await admin.rpc("finish_agent_run", {
    p_run: run.id,
    p_status: "failed",
    p_error: `nothing knows how to run "${run.kind}"`,
  });
  return "unknown_kind";
}

/**
 * Deep research, as a sequence rather than one enormous call.
 *
 * Split because the steps genuinely are different work with different costs:
 * planning the questions is cheap and benefits from a good model, answering
 * each one is separable, and the synthesis needs everything before it. Doing
 * all of that in one request would be a single point of failure that takes four
 * minutes to reach and cannot be resumed.
 *
 * The questions and findings live in `input`, so the run carries its own state
 * and a resumed step reads what the previous one wrote instead of holding
 * anything in memory between ticks.
 */
async function researchStep(admin: Admin, run: Run): Promise<string> {
  const topic = String(run.input.topic ?? "");
  const questions = (run.input.questions ?? []) as string[];
  const findings = (run.input.findings ?? []) as Array<{ question: string; answer: string }>;

  if (run.step === "queued" || run.step === "planning") {
    const asked = await ask(
      MODELS.deep,
      "You plan research. Return JSON only: {\"title\":string,\"questions\":[string]}. " +
        "title: what the finished report is about, under eight words, no quotes, not phrased as a request. " +
        "Between three and five questions, each answerable on its own, together covering the topic. " +
        "No preamble.",
      `Topic: ${topic}`,
    );

    const plan = safeParse(asked);
    const parsed = plan?.questions;
    const list = Array.isArray(parsed) ? parsed.slice(0, 5).map(String) : [];
    if (list.length === 0) throw new Error("no questions came back");
    // The report is named for what it is about, not by the sentence that asked
    // for it -- "Research what kinds of..." is a request, not a title.
    const title = typeof plan?.title === "string" && plan.title.trim() ? plan.title.trim().slice(0, 80) : null;

    await admin
      .from("agent_runs")
      .update({ input: { ...run.input, questions: list, findings: [], title } })
      .eq("id", run.id);

    await admin.rpc("advance_agent_run", {
      p_run: run.id,
      p_step: "researching",
      p_detail: `Broke it into ${list.length} questions`,
    });
    return "researching";
  }

  if (run.step === "researching") {
    const next = questions[findings.length];
    if (next === undefined) {
      await admin.rpc("advance_agent_run", {
        p_run: run.id,
        p_step: "synthesising",
        p_detail: "Reading everything back",
      });
      return "synthesising";
    }

    // One question per tick. Slower than looping, and the reason is that a
    // tick which dies loses one answer rather than all of them.
    const answer = await ask(
      MODELS.chat,
      "Answer in at most 120 words. Say plainly when you do not know something " +
        "rather than filling the gap -- an invented fact here ends up in somebody's content.",
      `${topic}\n\n${next}`,
    );

    const grown = [...findings, { question: next, answer }];
    await admin
      .from("agent_runs")
      .update({ input: { ...run.input, findings: grown } })
      .eq("id", run.id);

    await admin.rpc("append_agent_event", {
      p_run: run.id,
      p_type: "tool_end",
      p_payload: { question: next, done: grown.length, of: questions.length },
    });

    await admin.rpc("advance_agent_run", {
      p_run: run.id,
      p_step: "researching",
      p_detail: `Answered ${grown.length} of ${questions.length}`,
    });
    return `researching ${grown.length}/${questions.length}`;
  }

  if (run.step === "synthesising") {
    const body = findings.map((f) => `Q: ${f.question}\nA: ${f.answer}`).join("\n\n");
    const summary = await ask(
      MODELS.deep,
      "Write the findings as something a person can act on. Short paragraphs, no headings, " +
        "no hype. Name what is still unknown rather than papering over it.",
      `Topic: ${topic}\n\n${body}`,
    );

    // The report is an artefact, not just prose in a message: something that
    // can be exported, versioned, and referred to later as "that research".
    const { data: artifactId } = await admin.rpc("create_artifact", {
      p_user: run.user_id,
      p_kind: "research",
      p_title: typeof run.input.title === "string" && run.input.title
        ? run.input.title
        : topic.length > 80 ? `${topic.slice(0, 77)}...` : topic,
      p_body: { summary, questions, findings },
      p_thread: run.thread_id,
      p_run: run.id,
    });

    await admin.rpc("finish_agent_run", {
      p_run: run.id,
      p_status: "succeeded",
      p_result: { summary, questions, findings, artifact_id: artifactId },
    });

    // The conversation gets the answer where the conversation is, so somebody
    // returning to the thread finds it in place rather than in a notification.
    // The render hint names the artefact, so the card is drawn from the object
    // rather than re-parsed out of the prose.
    if (run.thread_id) {
      await admin.rpc("append_message", {
        p_thread: run.thread_id,
        p_role: "assistant",
        p_text: summary,
        p_render_hint: { kind: "artifact", artifact_id: artifactId },
        p_run: run.id,
      });
    }
    return "done";
  }

  throw new Error(`research has no step "${run.step}"`);
}

// ------------------------------------------------------------------ export

/**
 * A real file from something already made.
 *
 * One step, because building a document is milliseconds of work -- it runs on
 * the worker rather than inline in chat only so that it is a run like every
 * other, with events, a result, and a card that survives the app closing.
 *
 * The source is never modified. The file is a new artefact whose parent is the
 * source, so "the PDF of the research" is a walk up one column.
 */
async function exportStep(admin: Admin, run: Run): Promise<string> {
  const sourceId = String(run.input.artifact_id ?? "");
  const format = String(run.input.format ?? "pdf") as "docx" | "pdf" | "zip";

  const { data: sources } = await admin
    .from("artifacts")
    .select("id, kind, title, body, created_at")
    .eq("id", sourceId)
    .eq("user_id", run.user_id)
    .limit(1);
  const source = (sources ?? [])[0] as
    | { id: string; kind: string; title: string; body: Record<string, unknown>; created_at: string }
    | undefined;

  if (!source) {
    await admin.rpc("finish_agent_run", { p_run: run.id, p_status: "failed", p_error: "nothing to export" });
    await tell(admin, run, "I couldn't find what to export any more.");
    return "failed";
  }

  const doc = documentFrom(source);
  const base = slug(source.title) || source.kind;

  let bytes: Uint8Array;
  let mime: string;
  let filename: string;
  let kind: "document" | "package" = "document";
  let manifest: Array<{ path: string; size: number }> | undefined;

  if (format === "docx") {
    bytes = buildDocx(doc);
    mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
    filename = `${base}.docx`;
  } else if (format === "zip") {
    // Everything, in every form: the two readable files and the structured
    // content itself, so nothing is lost to a format that cannot hold it.
    const packed = buildZip(source.title, [
      { path: `${base}.docx`, bytes: buildDocx(doc) },
      { path: `${base}.pdf`, bytes: await buildPdf(doc) },
      { path: `${base}.json`, bytes: new TextEncoder().encode(JSON.stringify(source.body, null, 2)) },
    ]);
    bytes = packed.bytes;
    manifest = packed.manifest;
    mime = "application/zip";
    filename = `${base}.zip`;
    kind = "package";
  } else {
    bytes = await buildPdf(doc);
    mime = "application/pdf";
    filename = `${base}.pdf`;
  }

  const { data: made } = await admin.rpc("create_artifact", {
    p_user: run.user_id,
    p_kind: kind,
    p_title: filename,
    p_body: { format, filename, source_title: source.title, source_kind: source.kind, manifest },
    p_thread: run.thread_id,
    p_run: run.id,
    p_parent: source.id,
    p_status: "pending",
  });
  const artifactId = made as string;

  // Namespaced by owner first: the storage policy in 0032 lets a person read
  // only the folder named after them.
  const path = `${run.user_id}/${artifactId}/${filename}`;
  const { error: uploadError } = await admin.storage
    .from("artifacts")
    .upload(path, bytes, { contentType: mime, upsert: true });
  if (uploadError) throw new Error(`upload: ${uploadError.message}`);

  await admin.rpc("attach_artifact_file", {
    p_artifact: artifactId,
    p_path: path,
    p_mime: mime,
    p_size: bytes.byteLength,
  });

  await admin.rpc("finish_agent_run", {
    p_run: run.id,
    p_status: "succeeded",
    p_result: { artifact_id: artifactId },
  });

  const said = format === "zip"
    ? `Here's everything as a ZIP — ${manifest?.length ?? 0} files.`
    : `Here's the ${format.toUpperCase()}.`;
  await tell(admin, run, said, { kind: "artifact", artifact_id: artifactId });
  return "done";
}

/** Structured content as a document. Each kind says what its parts are; the
 *  export does not guess at a shape from prose. */
function documentFrom(source: { kind: string; title: string; body: Record<string, unknown>; created_at: string }): Document {
  const body = source.body ?? {};
  const date = new Date(source.created_at).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });

  if (source.kind === "research") {
    const findings = (body.findings ?? []) as Array<{ question: string; answer: string }>;
    return {
      title: source.title,
      subtitle: `Research · ${date}`,
      sections: [
        { heading: "Summary", paragraphs: paragraphs(String(body.summary ?? "")) },
        ...findings.map((f) => ({ heading: f.question, paragraphs: paragraphs(f.answer) })),
      ],
    };
  }

  if (source.kind === "campaign") {
    const pillars = (body.pillars ?? []) as Array<{ name: string; share: number; why: string }>;
    const facts = [
      body.goal ? `Goal: ${body.goal}` : "",
      body.audience ? `Audience: ${body.audience}` : "",
      body.appetite ? `Risk: ${body.appetite}` : "",
      `${body.days ?? 30} days, ${body.cadence ?? 1} post${Number(body.cadence ?? 1) === 1 ? "" : "s"} a day`,
    ].filter(Boolean);
    return {
      title: source.title,
      subtitle: `Campaign strategy · ${date}`,
      sections: [
        { heading: "The idea", paragraphs: paragraphs(String(body.summary ?? "")) },
        ...(body.angle ? [{ heading: "The angle", paragraphs: [String(body.angle)] }] : []),
        { heading: "Content pillars", paragraphs: pillars.map((p) => `${p.name} — ${p.share}%. ${p.why}`) },
        { heading: "Details", paragraphs: facts },
      ],
    };
  }

  if (Array.isArray(body.sections)) {
    return { title: source.title, subtitle: date, sections: body.sections as Document["sections"] };
  }

  if (Array.isArray(body.days)) {
    const days = body.days as Array<Record<string, unknown>>;
    return {
      title: source.title,
      subtitle: `${days.length} days · ${date}`,
      sections: [
        ...(body.summary ? [{ heading: "The idea", paragraphs: paragraphs(String(body.summary)) }] : []),
        ...days.map((d, i) => ({
          heading: `Day ${d.day ?? i + 1}${d.title ? ` — ${d.title}` : ""}`,
          paragraphs: [d.hook, d.caption, d.notes].filter(Boolean).map(String),
        })),
      ],
    };
  }

  // Anything else: every field, labelled. Plain rather than clever -- a field
  // name as a heading is ugly and never wrong.
  return {
    title: source.title,
    subtitle: date,
    sections: Object.entries(body).map(([key, value]) => ({
      heading: key.replace(/_/g, " "),
      paragraphs: [typeof value === "string" ? value : JSON.stringify(value, null, 2)],
    })),
  };
}

function paragraphs(text: string): string[] {
  return text
    .split(/\n{2,}/)
    .map((p) => p.replace(/^#+\s*/gm, "").replace(/\*\*/g, "").trim())
    .filter(Boolean);
}

function slug(title: string): string {
  return title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60);
}

// ---------------------------------------------------------------- generate

/** How long a generation may take before it is called stuck. Video on a busy
 *  provider runs to several minutes; forty is far past anything real. */
const POLLS_ALLOWED = 40;

/**
 * An image or a video, made by whatever the person has connected.
 *
 *   submitting  pick the model through the ladder and hand the job over
 *   waiting     ask, once a tick, whether it is done -- without writing an event
 *               each time, because "still working" forty times is noise
 *   saving      copy the bytes into our own storage, since provider links
 *               expire, and put the result into the conversation
 *
 * Nothing here names a provider. The ladder in `_shared/connectors/route.ts`
 * does the choosing, and a refusal comes back as a code with customer words.
 */
async function generateStep(admin: Admin, run: Run): Promise<string> {
  const capability = String(run.input.capability ?? "video_generation") as Capability;
  const what = capability === "image_generation" ? "image" : "video";

  if (run.step === "queued" || run.step === "submitting") {
    const references = await referencesFor(admin, run);

    let routed;
    try {
      routed = await routeSubmit(admin, {
        userId: run.user_id,
        capability,
        prompt: String(run.input.prompt ?? ""),
        options: {
          aspect_ratio: run.input.aspect_ratio ?? "9:16",
          ...(what === "video" && run.input.duration ? { duration: run.input.duration } : {}),
        },
        preferModel: typeof run.input.model === "string" ? run.input.model : undefined,
        references,
      });
    } catch (thrown) {
      if (thrown instanceof NothingCanDoThis) {
        await admin.rpc("finish_agent_run", { p_run: run.id, p_status: "failed", p_error: thrown.code });
        await tell(admin, run, refusal(thrown.code, what));
        return `failed ${thrown.code}`;
      }
      throw thrown;
    }

    await admin
      .from("agent_runs")
      .update({
        input: {
          ...run.input,
          submitted: routed.submitted,
          connection_id: routed.connectionId,
          provider: routed.providerSlug,
          model_used: routed.model,
          model_label: routed.modelLabel,
          polls: 0,
        },
      })
      .eq("id", run.id);

    await admin.rpc("advance_agent_run", {
      p_run: run.id,
      p_step: "waiting",
      p_detail: `${routed.modelLabel} is making it`,
      p_after: what === "image" ? "10 seconds" : "30 seconds",
    });
    return "waiting";
  }

  if (run.step === "waiting") {
    const submitted = run.input.submitted as Submitted;
    const polls = Number(run.input.polls ?? 0) + 1;

    let url = submitted.state === "done" ? submitted.outputUrl ?? null : null;
    let mime: string | undefined;

    if (!url) {
      const polled = await routePoll(admin, {
        connectionId: String(run.input.connection_id),
        ref: submitted.ref,
        statusUrl: submitted.statusUrl ?? "",
        capability,
      });

      if (polled.status === "failed" || polled.status === "nsfw") {
        const code = polled.status === "nsfw" ? "refused" : polled.code ?? "bad_output";
        await admin.rpc("finish_agent_run", { p_run: run.id, p_status: "failed", p_error: code });
        await tell(admin, run, refusal(code, what));
        return `failed ${code}`;
      }

      if (polled.status !== "completed" || !polled.videoUrl) {
        if (polls >= POLLS_ALLOWED) {
          await admin.rpc("finish_agent_run", { p_run: run.id, p_status: "failed", p_error: "timeout" });
          await tell(admin, run, `The ${what} was still not ready after ${POLLS_ALLOWED} minutes, so I stopped waiting. Nothing was saved.`);
          return "failed timeout";
        }
        // Back in the queue without an event. The card already says it is
        // being made; a new line every minute saying so again is noise.
        await admin
          .from("agent_runs")
          .update({
            input: { ...run.input, polls },
            run_after: new Date(Date.now() + (what === "image" ? 15_000 : 45_000)).toISOString(),
            claimed_by: null,
            lease_until: null,
          })
          .eq("id", run.id);
        return `waiting ${polls}`;
      }

      url = polled.videoUrl;
      mime = polled.mime;
    }

    return await saveGenerated(admin, run, url, mime, what);
  }

  throw new Error(`generate has no step "${run.step}"`);
}

/** Where the references for a generation come from, turned into something an
 *  adapter can hand over. Paths are re-checked against the owner here, not only
 *  where they were accepted -- the run's input is the last thing between a
 *  request and somebody else's file. */
async function referencesFor(
  admin: Admin,
  run: Run,
): Promise<Array<{ url?: string; providerRef?: string; kind: "image" | "video" }>> {
  const out: Array<{ url?: string; providerRef?: string; kind: "image" | "video" }> = [];

  const paths = (run.input.references ?? []) as Array<{ path: string; kind?: string }>;
  for (const reference of paths) {
    if (!reference.path?.startsWith(`${run.user_id}/`) || reference.path.includes("..")) continue;
    const { data } = await admin.storage.from("artifacts").createSignedUrl(reference.path, 3600);
    if (data?.signedUrl) out.push({ url: data.signedUrl, kind: reference.kind === "video" ? "video" : "image" });
  }

  // Animating something already made. By the provider's own handle when it was
  // made by the same provider -- no download and re-upload -- and by a signed
  // link to our copy otherwise.
  const sourceId = run.input.source_artifact_id;
  if (typeof sourceId === "string") {
    const { data: rows } = await admin
      .from("artifacts")
      .select("kind, provider, storage_path, body")
      .eq("id", sourceId)
      .eq("user_id", run.user_id)
      .limit(1);
    const source = (rows ?? [])[0] as
      | { kind: string; provider: string | null; storage_path: string | null; body: Record<string, unknown> }
      | undefined;

    if (source) {
      const kind = source.kind === "video" ? "video" : "image";
      const jobId = source.body?.provider_job_id;
      if (typeof jobId === "string" && source.provider) {
        out.push({ providerRef: jobId, kind });
      } else if (source.storage_path) {
        const { data } = await admin.storage.from("artifacts").createSignedUrl(source.storage_path, 3600);
        if (data?.signedUrl) out.push({ url: data.signedUrl, kind });
      }
    }
  }

  return out;
}

/** The result, copied into our storage and put in front of the person. */
async function saveGenerated(
  admin: Admin,
  run: Run,
  url: string,
  declaredMime: string | undefined,
  what: "image" | "video",
): Promise<string> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`download ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  const mime = declaredMime ?? response.headers.get("content-type") ?? (what === "image" ? "image/png" : "video/mp4");

  // A video is checked for being a video. A poster frame stored under an .mp4
  // name is the failure `_shared/media.ts` was written after.
  const extra: Record<string, unknown> = {};
  if (what === "video") {
    const checked = inspect(bytes, mime);
    if (!checked.ok) {
      await admin.rpc("finish_agent_run", { p_run: run.id, p_status: "failed", p_error: "bad_output" });
      await tell(admin, run, refusal("bad_output", what));
      return "failed bad_output";
    }
    extra.seconds = checked.seconds;
    extra.width = checked.width;
    extra.height = checked.height;
  } else if (!/^image\//.test(mime) || bytes.byteLength < 1024) {
    await admin.rpc("finish_agent_run", { p_run: run.id, p_status: "failed", p_error: "bad_output" });
    await tell(admin, run, refusal("bad_output", what));
    return "failed bad_output";
  }

  const ext = mime.includes("jpeg") ? "jpg" : mime.includes("webp") ? "webp" : mime.includes("png") ? "png" : what === "video" ? "mp4" : "png";
  const prompt = String(run.input.prompt ?? "");
  const submitted = run.input.submitted as Submitted;

  const { data: made } = await admin.rpc("create_artifact", {
    p_user: run.user_id,
    p_kind: what,
    p_title: prompt.length > 80 ? `${prompt.slice(0, 77)}...` : prompt || `New ${what}`,
    p_body: {
      prompt,
      model_label: run.input.model_label,
      // The provider's handle, kept so "animate this" can hand the image back
      // to the provider that made it instead of re-uploading it.
      provider_job_id: submitted.ref,
      source_artifact_id: run.input.source_artifact_id ?? null,
      ...extra,
    },
    p_thread: run.thread_id,
    p_run: run.id,
    p_parent: typeof run.input.source_artifact_id === "string" ? run.input.source_artifact_id : null,
    p_status: "pending",
  });
  const artifactId = made as string;

  const path = `${run.user_id}/${artifactId}/${what}.${ext}`;
  const { error: uploadError } = await admin.storage
    .from("artifacts")
    .upload(path, bytes, { contentType: mime, upsert: true });
  if (uploadError) throw new Error(`upload: ${uploadError.message}`);

  await admin.rpc("attach_artifact_file", {
    p_artifact: artifactId,
    p_path: path,
    p_mime: mime,
    p_size: bytes.byteLength,
  });
  // Who made it, and what it cost when the provider said. Never the estimate
  // copied across -- see the note at the top of 0032.
  await admin
    .from("artifacts")
    .update({
      provider: run.input.provider ?? null,
      model: run.input.model_used ?? null,
      estimated_cost: run.input.quoted_cost ?? null,
      actual_cost: submitted.charged ?? null,
    })
    .eq("id", artifactId);

  await admin.rpc("finish_agent_run", {
    p_run: run.id,
    p_status: "succeeded",
    p_result: { artifact_id: artifactId },
  });
  await tell(admin, run, `Here's your ${what}, made with ${run.input.model_label ?? "your provider"}.`, {
    kind: "artifact",
    artifact_id: artifactId,
  });
  return "done";
}

/** A failure code, said the way a person needs to hear it. The provider's own
 *  words stay on the run row for diagnosis and never reach the chat. */
function refusal(code: string, what: string): string {
  switch (code) {
    case "no_credits":
      return `Your provider is out of credits, so the ${what} wasn't made. Top up there and ask me again — nothing was charged here.`;
    case "needs_reconnect":
    case "bad_key":
      return `Your provider connection needs signing in again before I can make the ${what}. It's under the plus menu, in Connections.`;
    case "no_models":
      return `Nothing you've connected can make ${what === "image" ? "images" : "video"} right now.`;
    case "refused":
      return `The provider refused that prompt, so no ${what} was made. Try describing it differently.`;
    case "rate_limited":
      return `The provider is limiting requests right now. Ask again in a few minutes.`;
    case "provider_down":
      return `The provider isn't answering right now, so the ${what} wasn't made. Try again shortly.`;
    default:
      return `The ${what} didn't come back in a form I could use, so nothing was saved.`;
  }
}

/** Puts a line from the agent into the conversation the run belongs to. */
async function tell(admin: Admin, run: Run, text: string, hint: Record<string, unknown> | null = null): Promise<void> {
  if (!run.thread_id) return;
  await admin.rpc("append_message", {
    p_thread: run.thread_id,
    p_role: "assistant",
    p_text: text,
    p_render_hint: hint,
    p_run: run.id,
  });
}

async function ask(model: string, system: string, user: string): Promise<string> {
  if (!OPENAI_KEY) throw new Error("no model configured");

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      messages: [{ role: "system", content: system }, { role: "user", content: user }],
    }),
  });

  if (!response.ok) {
    throw new Error(`model ${response.status}: ${(await response.text()).slice(0, 200)}`);
  }
  const completion = await response.json();
  return completion.choices?.[0]?.message?.content ?? "";
}

/** Models are asked for JSON and sometimes wrap it in prose anyway. */
function safeParse(text: string): Record<string, unknown> | null {
  try {
    return JSON.parse(text);
  } catch {
    const braced = text.match(/\{[\s\S]*\}/);
    if (!braced) return null;
    try {
      return JSON.parse(braced[0]);
    } catch {
      return null;
    }
  }
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
