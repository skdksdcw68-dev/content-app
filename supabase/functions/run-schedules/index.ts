/**
 * Scheduled drops, woken every minute by pg_cron (0095, `tick_schedules`).
 *
 * Abel, 3 Nov 2026: "It can produce whenever, but it must send it at the exact
 * time I asked." So each drop is made AHEAD -- started when its time is close
 * enough for the slowest thing in it -- kept out of the conversation, and
 * posted with a ping in the minute it is due. Its jobs are exactly what the
 * chat would have started (saved on the schedule as `inputs`); "New ideas each
 * time" rewrites what they are of for every drop after the first.
 */
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, PublicError } from "../_shared/http.ts";
import { chargeForGeneration, refundCredits, type Charge } from "../_shared/credits.ts";
import { completionsFor, MODELS, OPENROUTER_KEY } from "../_shared/route.ts";
import { push } from "../_shared/push.ts";
import { recordUsage } from "../_shared/usage.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");

/** How long before its time a drop is started: long enough for its slowest job. */
const LEAD_MINUTES = { image: 20, voice: 10, video: 90 } as const;
/** How long a drop waits past its time for a job still running, then goes without it. */
const WAIT_MINUTES = 30;

type Schedule = {
  id: string;
  user_id: string;
  thread_id: string | null;
  request: string;
  summary: string;
  inputs: Array<Record<string, unknown>>;
  with_text: string | null;
  timezone: string;
  repeat: string;
  days: number[];
  time_of_day: string;
  ends_at: string | null;
  ends_after: number | null;
  delivered: number;
  next_at: string;
  options: { ping?: boolean; fresh?: boolean } | null;
};

type Drop = { id: string; schedule_id: string; due_at: string; run_ids: string[]; text: string | null };

Deno.serve(async (request) => {
  if (!CRON_SECRET || !sameText(request.headers.get("x-cron-secret") ?? "", CRON_SECRET)) {
    return json({ error: "no" }, 401);
  }
  const admin = createClient(SUPABASE_URL, SERVICE_KEY);
  const now = Date.now();
  const started: string[] = [];
  const delivered: string[] = [];

  // 1. Start what is close enough to its time.
  const horizon = new Date(now + LEAD_MINUTES.video * 60_000).toISOString();
  const { data: soon } = await admin.from("schedules").select("*").eq("status", "active").lte("next_at", horizon).limit(25);
  for (const schedule of (soon ?? []) as Schedule[]) {
    if (Date.parse(schedule.next_at) - now > leadFor(schedule.inputs) * 60_000) continue;
    // The unique (schedule, time) is the lock: a second tick gets nothing back.
    const { data: drop } = await admin
      .from("schedule_drops")
      .insert({ schedule_id: schedule.id, due_at: schedule.next_at })
      .select("id, schedule_id, due_at, run_ids, text")
      .maybeSingle();
    if (!drop) continue;
    try {
      await prepare(admin, schedule, drop as Drop);
      started.push(drop.id);
    } catch (error) {
      console.error("schedule: prepare", schedule.id, String(error));
      const why = error instanceof PublicError ? error.message : "Something went wrong making it.";
      await admin.from("schedule_drops").update({ status: "failed", error: why }).eq("id", drop.id);
      await say(admin, schedule, `Your scheduled ${schedule.summary} couldn't be made. ${why}`);
      if (schedule.options?.ping !== false) {
        await push(admin, schedule.user_id, "drop", { title: `Couldn't make your ${schedule.summary}`, body: why, thread: schedule.thread_id });
      }
      await advance(admin, schedule, schedule.next_at, false);
    }
  }

  // 2. Deliver what is due.
  const { data: due } = await admin
    .from("schedule_drops")
    .select("id, schedule_id, due_at, run_ids, text, schedules(*)")
    .eq("status", "making")
    .lte("due_at", new Date(now).toISOString())
    .limit(25);
  for (const row of due ?? []) {
    const schedule = (row as unknown as { schedules: Schedule }).schedules;
    if (!schedule) continue;
    if (await deliver(admin, schedule, row as unknown as Drop, now)) delivered.push(row.id);
  }

  return json({ started, delivered });
});

/** Minutes before its time a drop has to start, by the slowest thing in it. */
function leadFor(inputs: Array<Record<string, unknown>>): number {
  const kinds = inputs.map((input) => String(input.capability ?? ""));
  if (kinds.includes("video_generation")) return LEAD_MINUTES.video;
  if (kinds.includes("image_generation")) return LEAD_MINUTES.image;
  return LEAD_MINUTES.voice;
}

/** Charges and starts this drop's jobs, held for its time, and writes its words. */
async function prepare(admin: SupabaseClient, schedule: Schedule, drop: Drop) {
  let inputs = schedule.inputs;
  if (schedule.options?.fresh !== false && schedule.delivered > 0) {
    inputs = await freshIdeas(admin, schedule, inputs);
  }

  const charges: Array<Charge | null> = [];
  for (const input of inputs) {
    try {
      charges.push(await chargeForGeneration(admin, schedule.user_id, input));
    } catch (error) {
      for (const charge of charges) if (charge) await refundCredits(admin, schedule.user_id, charge.ref);
      throw error;
    }
  }

  // Pictures share a set, so the conversation draws them as one grid -- and a
  // set is allowed beside whatever else is running in the thread (0089).
  const together = inputs.every((input) => input.capability === "image_generation");
  const batch = crypto.randomUUID();
  const ids: string[] = [];
  for (const [index, input] of inputs.entries()) {
    const charge = charges[index];
    const vary = inputs.some((other, at) => at !== index && other.prompt === input.prompt);
    const { data: runId, error } = await admin.rpc("start_agent_run", {
      p_user: schedule.user_id,
      p_thread: schedule.thread_id,
      p_kind: "generate",
      p_input: {
        ...input,
        deliver_at: drop.due_at,
        drop_id: drop.id,
        ...(together ? { batch: { id: batch, index, of: inputs.length, vary } } : {}),
        ...(charge ? { credit_ref: charge.ref, credits: charge.credits } : {}),
      },
      p_brand: null,
      p_model: MODELS.chat,
    });
    if (error || !runId) {
      console.error("schedule: a job did not start", error?.message);
      if (charge) await refundCredits(admin, schedule.user_id, charge.ref);
      continue;
    }
    ids.push(runId as string);
  }
  if (ids.length === 0 && inputs.length > 0) throw new Error("no job started");

  const text = schedule.with_text ? await wordsFor(admin, schedule, inputs) : null;
  await admin.from("schedule_drops").update({ run_ids: ids, text }).eq("id", drop.id);
  kickWorker();
}

/** Posts a drop whose jobs are done (or have had long enough), and pings. */
async function deliver(admin: SupabaseClient, schedule: Schedule, drop: Drop, now: number): Promise<boolean> {
  if (drop.run_ids.length > 0) {
    const { data: runs } = await admin.from("agent_runs").select("id, status").in("id", drop.run_ids);
    const waiting = (runs ?? []).some((run) => ["queued", "running", "waiting_on_user"].includes(run.status));
    if (waiting && now < Date.parse(drop.due_at) + WAIT_MINUTES * 60_000) return false;
  }

  // Claimed before anything is posted: a slow tick and the next one never both deliver.
  const { data: claimed } = await admin
    .from("schedule_drops")
    .update({ status: "delivered", delivered_at: new Date().toISOString() })
    .eq("id", drop.id)
    .eq("status", "making")
    .select("id");
  if (!claimed || claimed.length === 0) return false;

  // Read after the claim: a job finishing from here on posts itself
  // (run-agent-jobs holds only while the drop is still "making").
  type Made = { id: string; status: string; result: Record<string, unknown> | null };
  const { data: runs } = drop.run_ids.length > 0
    ? await admin.from("agent_runs").select("id, status, result").in("id", drop.run_ids)
    : { data: [] as Made[] };
  const made = drop.run_ids
    .map((id) => ((runs ?? []) as Made[]).find((run) => run.id === id))
    .filter((run): run is Made => run?.status === "succeeded" && typeof run.result?.artifact_id === "string");

  if (schedule.thread_id) {
    const post = async (text: string, hint: Record<string, unknown>, run: string | null = null) => {
      const { error } = await admin.rpc("append_message", {
        p_thread: schedule.thread_id,
        p_role: "assistant",
        p_text: text,
        p_render_hint: hint,
        p_run: run,
      });
      if (error) console.error("schedule: append_message", error.message);
    };
    // The things themselves, one message each, as one set: the chat draws them
    // as a grid under one line, like pictures made on the spot.
    const lead = `Here ${made.length > 1 ? "are" : "is"} your ${schedule.summary}.`;
    const set = crypto.randomUUID();
    for (const run of made) {
      const result = run.result!;
      await post(lead, {
        kind: "artifact",
        artifact_id: result.artifact_id,
        artifact_kind: result.artifact_kind ?? "image",
        width: result.width ?? null,
        height: result.height ?? null,
        schedule_id: schedule.id,
        ...(made.length > 1 ? { batch: set, batch_of: made.length } : {}),
      }, run.id);
    }
    // Then the words that go with them, as a message of their own to copy.
    const words = drop.text?.trim();
    if (words) await post(words, { kind: "drop", schedule_id: schedule.id });
    else if (made.length === 0) await post(`Your scheduled ${schedule.summary} didn't come out this time.`, { kind: "drop", schedule_id: schedule.id });
  }
  if (schedule.options?.ping !== false) {
    await push(admin, schedule.user_id, "drop", {
      title: "Your scheduled drop is here",
      body: drop.text ? `${schedule.summary}. ${oneLine(drop.text)}` : `${schedule.summary}. Tap to see it.`,
      thread: schedule.thread_id,
    });
  }
  await advance(admin, schedule, drop.due_at, true);
  return true;
}

/** Moves the schedule on to its next time, or ends it. */
async function advance(admin: SupabaseClient, schedule: Schedule, after: string, counted: boolean) {
  const delivered = schedule.delivered + (counted ? 1 : 0);
  const { data: next } = await admin.rpc("schedule_next", {
    p_after: after,
    p_repeat: schedule.repeat,
    p_days: schedule.days,
    p_time: schedule.time_of_day,
    p_tz: schedule.timezone,
  });
  const over = !next ||
    (schedule.ends_after !== null && delivered >= schedule.ends_after) ||
    (schedule.ends_at !== null && Date.parse(next as string) > Date.parse(schedule.ends_at));
  await admin.from("schedules").update({
    delivered,
    next_at: over ? null : next,
    status: over ? "done" : "active",
    updated_at: new Date().toISOString(),
  }).eq("id", schedule.id).eq("status", "active");
}

/** The same brief, new things to make: "New ideas each time". */
async function freshIdeas(admin: SupabaseClient, schedule: Schedule, inputs: Array<Record<string, unknown>>) {
  const prompts = inputs.map((input) => String(input.prompt ?? ""));
  const answer = await ask(admin, schedule, "schedule_ideas", [
    "Someone gets this made for them on a schedule. Write NEW prompts for this delivery: the same brief, the",
    "same kind of thing and style, but different ideas from last time. Same count, same order.",
    'JSON only: {"prompts":[string]}',
    `Their request: ${schedule.request}`,
    `Last time's prompts: ${JSON.stringify(prompts)}`,
  ].join("\n"), true);
  try {
    const fresh = JSON.parse(answer ?? "{}")?.prompts;
    if (Array.isArray(fresh) && fresh.length === inputs.length && fresh.every((p) => typeof p === "string" && p.trim())) {
      return inputs.map((input, index) => ({ ...input, prompt: fresh[index] }));
    }
  } catch {
    // Last time's prompts, then: a drop that arrives beats a drop that is new.
  }
  return inputs;
}

/** The words that go with the drop ("a caption for each"). */
async function wordsFor(admin: SupabaseClient, schedule: Schedule, inputs: Array<Record<string, unknown>>) {
  const what = inputs.map((input, index) => `${index + 1}. ${String(input.prompt ?? "")}`).join("\n");
  return await ask(admin, schedule, "schedule_text", [
    `Write ${schedule.with_text} for the things below, made for someone's social media. Their request: ${schedule.request}`,
    "Plain text, ready to paste. Number them in the same order. No hashtags unless they asked for them. No intro.",
    what,
  ].join("\n"), false);
}

async function ask(admin: SupabaseClient, schedule: Schedule, kind: string, prompt: string, asJson: boolean) {
  if (!OPENAI_KEY && !OPENROUTER_KEY) return null;
  // Claude first while the OpenAI account has no credit.
  for (const model of OPENROUTER_KEY ? [MODELS.talk, MODELS.think] : [MODELS.quick, MODELS.chat]) {
    try {
      const to = completionsFor(model, OPENAI_KEY ?? "");
      const response = await fetch(to.url, {
        method: "POST",
        headers: { Authorization: `Bearer ${to.key}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          model,
          messages: [{ role: "user", content: prompt }],
          ...(asJson ? { response_format: { type: "json_object" } } : {}),
        }),
        signal: AbortSignal.timeout(40_000),
      });
      if (!response.ok) continue;
      const body = await response.json();
      await recordUsage(admin, { userId: schedule.user_id, kind, model: body.model ?? model, usage: body.usage ?? null }).catch(() => {});
      const text = body.choices?.[0]?.message?.content;
      if (typeof text === "string" && text.trim()) return text.trim();
    } catch {
      // The next model.
    }
  }
  return null;
}

/** A line in the conversation from Postpilot, outside any reply. */
async function say(admin: SupabaseClient, schedule: Schedule, text: string) {
  if (!schedule.thread_id) return;
  await admin.rpc("append_message", {
    p_thread: schedule.thread_id,
    p_role: "assistant",
    p_text: text,
    p_render_hint: { kind: "drop", schedule_id: schedule.id },
  });
}

/** Starts the job worker now rather than at its next minute. */
function kickWorker() {
  if (!CRON_SECRET) return;
  const kick = fetch(`${SUPABASE_URL}/functions/v1/run-agent-jobs`, {
    method: "POST",
    headers: { "x-cron-secret": CRON_SECRET, "Content-Type": "application/json" },
    body: "{}",
  }).catch(() => {});
  (globalThis as { EdgeRuntime?: { waitUntil?: (p: Promise<unknown>) => void } }).EdgeRuntime?.waitUntil?.(kick);
}

function oneLine(text: string): string {
  const line = text.replace(/\s+/g, " ").trim();
  return line.length > 140 ? `${line.slice(0, 137).trimEnd()}...` : line;
}

function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
