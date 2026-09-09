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
      "You plan research. Return JSON only: {\"questions\":[string]}. " +
        "Between three and five questions, each answerable on its own, together covering the topic. " +
        "No preamble.",
      `Topic: ${topic}`,
    );

    const parsed = safeParse(asked)?.questions;
    const list = Array.isArray(parsed) ? parsed.slice(0, 5).map(String) : [];
    if (list.length === 0) throw new Error("no questions came back");

    await admin
      .from("agent_runs")
      .update({ input: { ...run.input, questions: list, findings: [] } })
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

    await admin.rpc("finish_agent_run", {
      p_run: run.id,
      p_status: "succeeded",
      p_result: { summary, questions, findings },
    });

    // The conversation gets the answer where the conversation is, so somebody
    // returning to the thread finds it in place rather than in a notification.
    if (run.thread_id) {
      await admin.rpc("append_message", {
        p_thread: run.thread_id,
        p_role: "assistant",
        p_text: summary,
        p_render_hint: { kind: "research", run_id: run.id },
        p_run: run.id,
      });
    }
    return "done";
  }

  throw new Error(`research has no step "${run.step}"`);
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
