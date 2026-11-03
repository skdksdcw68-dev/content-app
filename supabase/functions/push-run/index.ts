/**
 * Called by the database when a job finishes (trigger `agent_runs_push`, 0094)
 * and pings the person: "Your video is ready". A set of pictures pings once,
 * when its last picture is done. Jobs held for a scheduled delivery stay quiet;
 * the delivery pings instead.
 *
 * Not called by the app. The shared cron secret is the key, as for the other
 * functions the database wakes.
 */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json } from "../_shared/http.ts";
import { firstTime, push, type PushKind } from "../_shared/push.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");

const FINISHED = ["succeeded", "failed", "cancelled"];

Deno.serve(async (request) => {
  if (!CRON_SECRET || !sameText(request.headers.get("x-cron-secret") ?? "", CRON_SECRET)) {
    return json({ error: "no" }, 401);
  }
  const { run_id: runId } = await request.json().catch(() => ({}));
  if (typeof runId !== "string") return json({ error: "run_id" }, 400);

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);
  const { data: run } = await admin
    .from("agent_runs")
    .select("id, user_id, thread_id, kind, status, input")
    .eq("id", runId)
    .maybeSingle();
  if (!run || !FINISHED.includes(run.status)) return json({ sent: 0 });
  // Held for a scheduled delivery: the delivery itself is the ping.
  if (run.input?.deliver_at) return json({ sent: 0, held: true });

  const kind = kindOf(run);
  if (!kind) return json({ sent: 0 });

  // A set of pictures: wait for the last one, then ping once for all of them.
  const batch = run.input?.batch;
  let count = 1;
  let failed = run.status !== "succeeded";
  if (batch?.id) {
    const { data: set } = await admin
      .from("agent_runs")
      .select("status")
      .eq("user_id", run.user_id)
      .eq("input->batch->>id", batch.id);
    const runs = set ?? [];
    if (runs.some((r) => !FINISHED.includes(r.status))) return json({ sent: 0, waiting: true });
    count = runs.filter((r) => r.status === "succeeded").length;
    failed = count === 0;
  }
  if (!(await firstTime(admin, batch?.id ? `batch:${batch.id}` : `run:${run.id}`))) return json({ sent: 0, already: true });

  const sent = await push(admin, run.user_id, kind, {
    title: titleFor(kind, count, failed),
    body: failed ? "Tap to see what happened." : subjectOf(run),
    thread: run.thread_id,
  });
  return json({ sent });
});

function kindOf(run: { kind: string; input: Record<string, unknown> | null }): PushKind | null {
  if (run.kind === "story") return "video";
  if (run.kind === "research") return "report";
  if (run.kind !== "generate") return null;
  switch (run.input?.capability) {
    case "image_generation": return "picture";
    case "video_generation": return "video";
    case "voice_generation": return "voice";
    default: return null;
  }
}

function titleFor(kind: PushKind, count: number, failed: boolean): string {
  const noun = { picture: "picture", video: "video", voice: "voice", report: "report", reply: "reply", drop: "delivery" }[kind];
  if (failed) return `Your ${noun} didn't finish`;
  if (count > 1) return `Your ${count} ${noun}s are ready`;
  return `Your ${noun} is ready`;
}

/** What it was of, in a line: the prompt it was made from. */
function subjectOf(run: { input: Record<string, unknown> | null }): string {
  const said = [run.input?.prompt, run.input?.subject, run.input?.topic].find((v) => typeof v === "string" && v.trim());
  if (typeof said !== "string") return "Tap to see it.";
  const line = said.trim().replace(/\s+/g, " ");
  const short = line.length > 110 ? `${line.slice(0, 107).trimEnd()}...` : line;
  return short.charAt(0).toUpperCase() + short.slice(1);
}

function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
