/**
 * The agent, as a conversation rather than a form.
 *
 * The previous version took one message and returned three ideas as JSON. That
 * is a generator with a text field, not an agent: it could not be asked a
 * follow-up, it could not say "I don't know that about your brand", and it had
 * no way to tell you what it was doing while it did it.
 *
 * This one holds a conversation and streams the reply as it is written. Three
 * things are deliberate:
 *
 *   1. **It streams over SSE.** Short replies fit comfortably inside the Edge
 *      Function wall clock. Long work does not, which is exactly why planning
 *      thirty days stays in `propose-plan` and is offered here as an action
 *      rather than done inline.
 *   2. **The steps are emitted as they happen**, from the server, after the
 *      work is actually done. A progress line the client invents is decoration;
 *      one the server sends after reading the brand is a receipt.
 *   3. **The facts come from `brand_memory`**, and the model is told plainly
 *      that they are all it knows. Everything in `planner-invents-facts`
 *      applies here: told to be specific with nothing to be specific about, a
 *      small model makes things up.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { leftToUs, missingForPlan, MODELS, route, vagueSubject } from "../_shared/route.ts";
import { choicesFor, matchModels, settlesOn } from "../_shared/connectors/choose.ts";
import { balanceFor, candidatesFor } from "../_shared/connectors/route.ts";
import type { Capability } from "../_shared/connectors/contract.ts";
import { rediscover } from "../_shared/connectors/discovery.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
/** Only ever used to write the assistant's own turn. The client's policy in
 *  0002 allows it to insert `role = 'user'` and nothing else, on purpose: an
 *  assistant message the app could write is one it could forge. */
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");

/** The reply itself runs on the top tier. It used to run on the middle one,
 *  and the result was called "boring, 0% understanding" by the person it was
 *  for -- the conversation IS the product, so this is where quality is spent.
 *  The router and the classification around it stay cheaper; see `MODELS` in
 *  _shared/route.ts. */
const MODEL = MODELS.deep;

/** How much conversation goes back to the model. Past this the cost grows for
 *  context nobody refers to; a chat that has run longer keeps its most recent
 *  turns, which is where the pronouns point. */
const TURNS_KEPT = 12;

interface Turn {
  role: "user" | "assistant";
  content: string;
}

/**
 * Something a button asked for, as data rather than as a sentence.
 *
 * Tapping "PDF" on a report card used to have to travel as the words "export
 * it as a PDF" and survive the router reading them back -- which works until it
 * does not, and then the tap does something else. A button knows exactly what
 * it means, so it says so.
 */
type Action =
  | { type: "export"; artifactId: string; format: "docx" | "pdf" | "zip" }
  | {
    type: "generate";
    capability: Capability;
    prompt: string;
    /** The `externalId` of a picked model. Absent means Auto. */
    model?: string;
    references?: string[];
    /** What was set on the card: resolution, duration, aspect ratio. */
    settings?: Record<string, unknown>;
    /** The price the card showed for exactly these settings. */
    quoted?: { amount: number; unit: string } | null;
  }
  | { type: "animate"; artifactId: string; prompt?: string }
  /** Every question on a card, answered by tapping. The values are the
   *  options' own values, so nothing is parsed back out of a sentence. */
  | { type: "answers"; answers: Record<string, string>; request?: string; days?: number };

interface Body {
  messages?: Turn[];
  /** The conversation this belongs to. Omitted on the first turn, and the id of
   *  the thread opened for it comes back on the stream. */
  threadId?: string;
  brandId?: string;
  action?: Action;
  /** Files the person attached to this turn, as paths in their own uploads
   *  folder. Checked against the caller before anything reads them. */
  attachments?: string[];
}

/** One server-sent line. Kept to a single shape so the client parses one thing. */
function sse(event: Record<string, unknown>): string {
  return `data: ${JSON.stringify(event)}\n\n`;
}

/**
 * A subject that only points back at the picture, and so says nothing about
 * what should happen in the video.
 *
 * "animate this photo" came back from the router as the subject "a photo to
 * animate". Sent as the prompt, that is what the model would have drawn. Take
 * the asking-for-motion words out and see whether anything of substance is
 * left -- "the clouds drift" survives, "a photo to animate" does not.
 */
function pointsAtIt(subject: string): boolean {
  return vagueSubject(
    subject.replace(/\b(animate[sd]?|animating|animation|move[sd]?|moving|motion|bring|brought|life|alive)\b/gi, " "),
  );
}

/** What a capability leaves behind, in one word, and how to say more than one
 *  of them. Everything the agent says about making something goes through
 *  here, so a new kind of model is a line rather than a branch per sentence. */
function nounFor(capability: string): string {
  if (capability === "image_generation") return "image";
  if (capability === "audio_generation") return "track";
  if (capability === "voice_generation") return "voice clip";
  return "video";
}

function nounsFor(capability: string): string {
  if (capability === "image_generation") return "images";
  if (capability === "audio_generation") return "music or sound";
  if (capability === "voice_generation") return "voice";
  return "video";
}

/** A provider's slug as a person writes it: "higgsfield" -> "Higgsfield",
 *  "open_router" -> "Open Router". Said this way so no provider's name is
 *  written into the words the agent speaks. */
function pretty(slug?: string | null): string {
  return (slug ?? "")
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    if (!OPENAI_KEY) throw new PublicError("The writer is not configured yet.", 503);

    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);

    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const body = (await request.json().catch(() => ({}))) as Body;
    const history = (body.messages ?? [])
      .filter((turn) => typeof turn?.content === "string" && turn.content.trim())
      .slice(-TURNS_KEPT);

    // Only paths inside the caller's own uploads folder. Anything else is
    // dropped rather than refused: a stale path from a previous session is not
    // worth failing the turn over, and a crafted one gets nothing.
    const attachments = (body.attachments ?? [])
      .filter((path) =>
        typeof path === "string" &&
        path.startsWith(`${auth.user.id}/uploads/`) &&
        !path.includes("..")
      )
      .slice(0, 4);

    // A photo on its own is a message -- "here, do something with this" -- so
    // an empty turn carrying one is allowed, and only an empty turn carrying
    // nothing is refused.
    const mine = history.length > 0 && history[history.length - 1].role === "user"
      ? history[history.length - 1].content
      : "";
    if (!mine && attachments.length === 0) throw new PublicError("Say something first.");

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const asked = mine;

    // The conversation is kept server-side, not in the view. A chat that dies
    // when the app is swiped away is not a command centre -- and the agent is
    // going to need to work while the phone is closed, which it cannot do
    // against a transcript that only exists on the phone.
    //
    // Opened before the stream starts so the id can be sent on its first frame:
    // a client that loses the connection halfway still knows where its turn
    // went, rather than opening a second thread on the retry.
    let threadId = body.threadId ?? null;
    if (!threadId) {
      const { data: opened, error: openError } = await asUser
        .rpc("open_thread", { p_brand: body.brandId ?? null, p_title: asked || "A photo" });
      if (openError) console.error("open_thread", openError);
      threadId = (opened as string | null) ?? null;
    }

    if (threadId) {
      // As the person, through the client policy that lets them write only
      // their own turns. The assistant's turn is written below with the service
      // role, because a message the client could author is one it could forge.
      const { error: sayError } = await asUser.rpc("append_message", {
        p_thread: threadId,
        p_role: "user",
        p_text: asked,
        // Kept with the turn so a reopened conversation still shows what was
        // attached, not a message referring to a picture that is not there.
        ...(attachments.length > 0 ? { p_render_hint: { kind: "attachments", paths: attachments } } : {}),
      });
      if (sayError) console.error("append_message user", sayError);
    }

    const stream = new ReadableStream({
      async start(controller) {
        const send = (event: Record<string, unknown>) =>
          controller.enqueue(new TextEncoder().encode(sse(event)));

        /** Everything the assistant said this turn, kept so it can be stored
         *  once the stream ends. Storing per delta would be one write per
         *  token and a transcript full of fragments. */
        let said = "";

        const remember = async (hint: Record<string, unknown> | null = null) => {
          if (!threadId || (!said && !hint)) return;
          const { error } = await admin.rpc("append_message", {
            p_thread: threadId,
            p_role: "assistant",
            p_text: said,
            p_render_hint: hint,
          });
          if (error) console.error("append_message assistant", error);
        };

        if (threadId) send({ t: "thread", id: threadId });

        const speak = (...chunks: string[]) => {
          for (const chunk of chunks) {
            if (!chunk) continue;
            said += chunk;
            send({ t: "delta", v: chunk });
          }
        };

        const finish = () => {
          send({ t: "done" });
          controller.close();
        };

        /**
         * Hands long work to the worker and tells the app which run to watch.
         *
         * The reply ends here, on purpose. The run keeps going on the cron
         * worker whether or not this connection survives, and the app follows
         * it through `run_events` -- so closing the app halfway through a
         * research job loses nothing, and the result lands in this thread.
         */
        const startRun = async (kind: string, input: Record<string, unknown>, brandId: string | null) => {
          const { data: runId, error } = await admin.rpc("start_agent_run", {
            p_user: auth.user!.id,
            p_thread: threadId,
            p_kind: kind,
            p_input: input,
            p_brand: brandId,
            p_model: MODELS.chat,
          });
          if (error || !runId) throw error ?? new Error("the run did not start");
          send({ t: "run", id: runId, kind });
          await remember({ kind: "run", run_id: runId, run_kind: kind });
          finish();
        };

        /**
         * The confirm-and-reason half of planning: a strategy the person can
         * read and approve before a single post is written.
         *
         * 0024 built the tables for this and said agent-chat would draft the
         * strategy. It never did, so answering the questions put the answers
         * in the transcript and nowhere else, and the next turn asked them
         * again. This is that missing step.
         *
         * The card it produces is a `campaign` artefact. Approving it is the
         * person's act, through `approve_strategy`, which refuses the service
         * role -- the agent cannot approve its own plan.
         */
        const draftCampaign = async (
          brand: { id: string; name: string; niche?: string; audience?: string },
          strategyId: string,
          request: string,
          days: number,
        ) => {
          const { data: rows } = await asUser.rpc("current_strategy", { p_brand: brand.id });
          const strategy = ((rows ?? []) as Array<Record<string, unknown>>).find((row) => row.id === strategyId) ??
            (rows ?? [])[0] ?? {};

          const { data: facts } = await asUser
            .from("brand_memory").select("fact").eq("brand_id", brand.id).limit(40);
          const known = ((facts ?? []) as Array<{ fact: string }>).map((row) => row.fact).filter(Boolean);

          send({ t: "step", kind: "planning", detail: "Working out the strategy" });

          const response = await fetch("https://api.openai.com/v1/chat/completions", {
            method: "POST",
            headers: { Authorization: `Bearer ${OPENAI_KEY}`, "Content-Type": "application/json" },
            body: JSON.stringify({
              model: MODELS.deep,
              response_format: { type: "json_object" },
              messages: [
                {
                  role: "system",
                  content: [
                    "You design a short-form video campaign strategy for one account. JSON only:",
                    '{"title":string,"summary":string,"angle":string,"pillars":[{"name":string,"share":number,"why":string}]}',
                    "title: under seven words, what the campaign is. summary: two or three plain sentences on what it does and why it fits the goal.",
                    "angle: one sentence, the through-line every post shares. pillars: three or four content themes whose shares sum to 100.",
                    "Use only the facts given. Never invent a feature, a customer, a number, a price or a date. No hype words.",
                  ].join("\n"),
                },
                {
                  role: "user",
                  content: [
                    `Account: ${brand.name}. Subject: ${brand.niche || "not stated"}.`,
                    `Request: ${request || "plan the next stretch of content"}`,
                    `Days: ${days}. Goal: ${strategy.goal ?? "not stated"}. Appetite: ${strategy.appetite ?? "balanced"}.`,
                    `Audience: ${strategy.audience || brand.audience || "not stated"}. Posts per day: ${strategy.cadence ?? 1}.`,
                    known.length > 0 ? `Facts:\n${known.map((f) => `- ${f}`).join("\n")}` : "Facts: none recorded.",
                  ].join("\n"),
                },
              ],
            }),
          });
          if (!response.ok) throw new Error(`strategy ${response.status}`);
          const drafted = JSON.parse((await response.json()).choices?.[0]?.message?.content ?? "{}");

          const pillars = (Array.isArray(drafted.pillars) ? drafted.pillars : [])
            .slice(0, 4)
            .map((p: Record<string, unknown>) => ({
              name: String(p.name ?? "").slice(0, 40),
              share: Math.max(0, Math.min(100, Math.round(Number(p.share) || 0))),
              why: String(p.why ?? "").slice(0, 200),
            }))
            .filter((p: { name: string }) => p.name);
          const summary = String(drafted.summary ?? "").slice(0, 600);

          // The reasoning is the agent's to write; an approved strategy is
          // never rewritten underneath the approval, so this is skipped then.
          if (!strategy.approved_at) {
            await admin.rpc("draft_strategy", { p_strategy: strategyId, p_summary: summary, p_pillar_mix: pillars });
          }

          const { data: artifactId } = await admin.rpc("create_artifact", {
            p_user: auth.user!.id,
            p_kind: "campaign",
            p_title: String(drafted.title ?? `${days}-day plan`).slice(0, 80),
            p_body: {
              strategy_id: strategyId,
              request,
              days,
              cadence: strategy.cadence ?? 1,
              goal: strategy.goal ?? null,
              appetite: strategy.appetite ?? null,
              audience: strategy.audience || brand.audience || null,
              summary,
              angle: String(drafted.angle ?? "").slice(0, 300),
              pillars,
            },
            p_thread: threadId,
          });

          speak(
            strategy.approved_at
              ? "Here's the strategy you approved. I can write the posts now."
              : `Here's what I'd run for ${brand.name}. Approve it and I'll write every post — nothing goes out until you approve those too.`,
          );
          send({ t: "artifact", id: artifactId });
          await remember({ kind: "artifact", artifact_id: artifactId });
          finish();
        };

        /**
         * The model offer this reply answers, if the last thing Autocast said
         * was one. A typed "use Kling" or "make it a photo" is a reply to it,
         * and needs what it was offered for: the subject, the references, and
         * any settings already asked for.
         */
        const lastOffer = async (): Promise<{
          capability: string;
          request: string;
          references: string[];
          settings: Record<string, unknown>;
          sourceArtifactId: string | null;
        } | null> => {
          if (!threadId) return null;
          const { data } = await admin
            .from("messages")
            .select("render_hint")
            .eq("thread_id", threadId)
            .eq("role", "assistant")
            .order("seq", { ascending: false })
            .limit(1);
          const hint = (data ?? [])[0]?.render_hint as Record<string, unknown> | null | undefined;
          if (hint?.kind !== "models") return null;
          const choices = hint.choices as { capability?: string } | undefined;
          return {
            capability: String(choices?.capability ?? ""),
            request: String(hint.request ?? ""),
            references: Array.isArray(hint.references) ? (hint.references as string[]) : [],
            settings: (hint.settings as Record<string, unknown>) ?? {},
            sourceArtifactId: typeof hint.source_artifact_id === "string" ? hint.source_artifact_id : null,
          };
        };

        /**
         * The make request waiting on its subject, if the last thing Autocast
         * said was "what should it be of?". The reply IS the subject -- "a cup
         * of tea" on its own reads as chat -- and the model and settings named
         * before the question still apply.
         */
        const lastAwaiting = async (): Promise<{
          capability: string;
          model: string | null;
          settings: Record<string, unknown>;
          references: string[];
        } | null> => {
          if (!threadId) return null;
          const { data } = await admin
            .from("messages")
            .select("render_hint")
            .eq("thread_id", threadId)
            .eq("role", "assistant")
            .order("seq", { ascending: false })
            .limit(1);
          const hint = (data ?? [])[0]?.render_hint as Record<string, unknown> | null | undefined;
          if (hint?.kind !== "awaiting_subject") return null;
          return {
            capability: String(hint.capability ?? "image_generation"),
            model: typeof hint.model === "string" ? hint.model : null,
            settings: (hint.settings as Record<string, unknown>) ?? {},
            references: Array.isArray(hint.references) ? (hint.references as string[]) : [],
          };
        };

        /**
         * Pictures they sent themselves, in the last couple of turns.
         *
         * Attachments travel with the turn they were sent on, so "animate it"
         * one message later arrives with none -- and the photo they are
         * plainly talking about would be replaced by an older picture the
         * agent had made.
         */
        const recentAttachments = async (): Promise<string[]> => {
          if (!threadId) return [];
          const { data } = await admin
            .from("messages")
            .select("render_hint")
            .eq("thread_id", threadId)
            .eq("role", "user")
            .order("seq", { ascending: false })
            .limit(3);
          for (const row of (data ?? []) as Array<{ render_hint: Record<string, unknown> | null }>) {
            const hint = row.render_hint;
            if (hint?.kind !== "attachments") continue;
            const paths = hint.paths;
            if (Array.isArray(paths) && paths.length > 0) return paths.map(String);
          }
          return [];
        };

        /** Everything made in this conversation that is a file: the pictures,
         *  the videos, the music, and any document already exported. */
        const madeHere = async (): Promise<Array<{ id: string; kind: string }>> => {
          if (!threadId) return [];
          const { data } = await asUser.rpc("thread_artifacts", { p_thread: threadId });
          return ((data ?? []) as Array<{ id: string; kind: string }>)
            .filter((row) => ["image", "video", "audio", "document", "package"].includes(row.kind));
        };

        /** Artefacts in this conversation, newest first -- what "it" means. */
        const latestExportable = async (): Promise<{ id: string; kind: string; title: string } | null> => {
          if (!threadId) return null;
          const { data } = await asUser.rpc("thread_artifacts", { p_thread: threadId });
          const rows = (data ?? []) as Array<{ id: string; kind: string; title: string }>;
          return rows.find((row) => ["research", "plan", "campaign"].includes(row.kind)) ?? null;
        };

        /** Why a job ended, in the words a person would use. */
        const REASON: Record<string, string> = {
          no_credits: "not enough credits for that model",
          needs_reconnect: "the connection needed signing in again",
          bad_key: "the connection was refused",
          no_models: "no connected model could do it",
          refused: "the provider refused the prompt",
          rate_limited: "the provider was busy",
          provider_down: "the provider was down",
          bad_output: "the result wasn't usable",
          timeout: "it took too long",
        };

        /**
         * What is true about their account right now, for the reply to use.
         *
         * The reason "so do I have to top up?" got "I don't handle payments":
         * the reply had the brand's facts and nothing else. It did not know a
         * video had failed a minute earlier, what it had cost, or what they
         * had left. Now it does -- and the balance is fetched only when they
         * are asking about money, which is the one time it is worth a call.
         */
        const describeState = async (checkCredits: boolean): Promise<string> => {
          const none = Promise.resolve({ data: [] as unknown[] });
          const [connsRead, runsRead, madeRead, offerRead] = await Promise.all([
            asUser.rpc("my_connections"),
            threadId
              ? admin.from("agent_runs").select("kind, status, error, input, result, created_at")
                .eq("thread_id", threadId).eq("user_id", auth.user!.id)
                .order("created_at", { ascending: false }).limit(4)
              : none,
            threadId ? asUser.rpc("thread_artifacts", { p_thread: threadId }) : none,
            threadId
              ? admin.from("messages").select("render_hint")
                .eq("thread_id", threadId).eq("render_hint->>kind", "models")
                .order("seq", { ascending: false }).limit(1)
              : none,
          ]);

          const lines: string[] = [];
          const conns = (connsRead.data ?? []) as Array<{
            id: string; provider_name: string; auth_kind: string | null; status: string;
            capabilities: string[]; model_count: number;
          }>;
          if (conns.length === 0) {
            lines.push("Connected: nothing yet. They can connect Higgsfield from + then Connections.");
          }
          for (const c of conns) {
            const kinds = (c.capabilities ?? []).map((k) => k.replace("_generation", "")).join(", ");
            lines.push(
              `Connected: ${c.provider_name} (${c.auth_kind === "api_key" ? "pasted key" : "signed in"}, ${c.status}), ` +
                `${c.model_count} models${kinds ? ` for ${kinds}` : ""}.`,
            );
          }

          const runs = (runsRead.data ?? []) as Array<{
            kind: string; status: string; error: string | null;
            input: Record<string, unknown>; result: Record<string, unknown> | null;
          }>;
          if (runs.length > 0) {
            lines.push("Recent work in this conversation, newest first:");
            for (const r of runs) {
              const i = r.input ?? {};
              const what = r.kind === "generate"
                ? (i.capability === "video_generation" && i.source_artifact_id
                  ? "animation (video)"
                  : nounFor(String(i.capability)))
                : r.kind;
              const label = i.model_label ?? (Array.isArray(r.result?.attempts) ? String((r.result!.attempts as string[])[0] ?? "").split(":")[0] : "");
              const quoted = i.quoted_cost as { amount?: number; unit?: string } | null;
              const outcome = r.status === "succeeded"
                ? "made"
                : r.status === "failed"
                ? `failed: ${REASON[r.error ?? ""] ?? r.error ?? "unknown"}`
                : "still running";
              lines.push(
                `- ${what}${label ? ` with ${label}` : ""}${quoted?.amount != null ? ` (quoted ${trim(quoted.amount)} ${quoted.unit})` : ""}` +
                  `${i.prompt ? ` of "${String(i.prompt).slice(0, 80)}"` : i.topic ? ` on "${String(i.topic).slice(0, 80)}"` : ""}: ${outcome}`,
              );
            }
          }

          const made = (madeRead.data ?? []) as Array<{ kind: string; title: string }>;
          if (made.length > 0) {
            lines.push(`Made in this conversation: ${made.slice(0, 6).map((a) => `${a.kind} "${a.title.slice(0, 50)}"`).join("; ")}.`);
          }

          const hint = ((offerRead.data ?? []) as Array<{ render_hint: Record<string, unknown> }>)[0]?.render_hint;
          const options = ((hint?.choices as { options?: Array<{ label: string; cost: { amount: number | null; unit: string } }> })?.options ?? [])
            .filter((o) => o.cost?.amount != null);
          if (options.length > 0) {
            lines.push(`Prices seen for "${String(hint?.request ?? "").slice(0, 60)}": ${
              options.slice(0, 8).map((o) => `${o.label} ${trim(o.cost.amount!)} ${o.cost.unit}`).join(", ")
            }.`);
          }

          if (checkCredits) lines.push(await balanceLine());

          return `STATE:\n${lines.join("\n")}`;
        };

        /** The balance, as one line of STATE. Only when they asked about money. */
        const balanceLine = async (): Promise<string> => {
          const { data } = await asUser.rpc("my_connections");
          const door = ((data ?? []) as Array<{ id: string; provider_name: string; auth_kind: string | null; status: string }>)
            .find((c) => c.auth_kind !== "api_key" && c.status === "active");
          if (!door) return "Balance: nothing connected that has one.";
          send({ t: "step", kind: "reading", detail: `Checking your ${door.provider_name} credits` });
          const balance = await balanceFor(admin, door.id);
          return balance
            ? `Balance on ${door.provider_name}: ${trim(balance.amount)} ${balance.unit}${balance.plan ? ` (${balance.plan} plan)` : ""}.`
            : `Balance: ${door.provider_name} didn't say just now.`;
        };

        const trim = (n: number) => String(Number(n.toFixed(2)));
        const priced = (cost: { amount: number | null; unit: string }) =>
          cost.amount === null ? "" : ` (${trim(cost.amount)} ${cost.unit})`;

        /**
         * Offer, or start, one image or video. The one place that decides, so
         * "make me…", a typed model name and the Animate button all behave the
         * same way -- Animate used to skip all of this and take the first video
         * model on the list, which cost 75 credits against a balance of 26.
         *
         * The balance is read here and nowhere else in a normal turn: a price
         * is about to be put in front of somebody, and "can I afford it" is the
         * question that price raises.
         */
        const produce = async (job: {
          capability: Capability;
          prompt: string;
          settings: Record<string, unknown>;
          references: string[];
          sourceArtifactId?: string | null;
          only?: string[];
          settled?: boolean;
          unmatched?: boolean;
          named?: string | null;
          brandId: string | null;
          intro?: string;
        }) => {
          const noun = nounFor(job.capability);
          const aspect = String(job.settings.aspect_ratio ?? "9:16");
          const withPicture = job.references.length > 0 || Boolean(job.sourceArtifactId);

          const pool = await candidatesFor(admin, auth.user!.id, job.capability);
          const door = pool.find((c) => c.authKind !== "api_key") ?? pool[0];
          if (pool.length > 0) {
            send({ t: "step", kind: "reading", detail: `Checking prices for ${job.prompt}` });
          }
          const balance = door ? await balanceFor(admin, door.connectionId) : null;

          const intentFor = {
            aspectRatio: aspect,
            seconds: typeof job.settings.duration === "number"
              ? job.settings.duration
              : noun === "video"
              ? 5
              : noun === "track"
              ? 15
              : undefined,
            // Asked of the provider with this very prompt and these settings,
            // so the price on each row is what this job costs.
            quote: { prompt: job.prompt, options: { aspect_ratio: aspect, ...job.settings } },
            withPicture,
            only: job.only,
            balance,
          };
          let choices = await choicesFor(admin, auth.user!.id, job.capability, intentFor);

          // Nothing found, but something is signed in: ask it again before
          // saying no. The first real sign-in lost its model list to a failed
          // write, and chat then said nothing could make an image.
          if (choices.options.length === 0) {
            const { data: signedIn } = await asUser
              .from("connections")
              .select("id, auth_kind, provider_slug")
              .eq("status", "active")
              .is("revoked_at", null);
            const doors = ((signedIn ?? []) as Array<{ id: string; auth_kind: string | null; provider_slug?: string }>)
              .filter((row) => row.auth_kind !== "api_key");
            if (doors.length > 0) {
              // Named from the connection, never written in: a second provider
              // must not be announced as the first one.
              const who = pretty(doors[0].provider_slug) || "your generator";
              send({ t: "step", kind: "reading", detail: `Asking ${who} what it can make` });
              for (const row of doors) {
                try {
                  await rediscover(admin, row.id);
                } catch (thrown) {
                  console.error("rediscover", thrown instanceof Error ? thrown.message : thrown);
                }
              }
              choices = await choicesFor(admin, auth.user!.id, job.capability, intentFor);
            }
          }

          if (choices.options.length === 0) {
            speak(
              `Nothing you've connected can make ${nounsFor(job.capability)} yet. `,
              "Connect a generator from the plus menu and I'll start straight away.",
            );
            await remember();
            return finish();
          }

          const credits = balance ? `${trim(balance.amount)} ${balance.unit}` : null;
          const affordable = choices.options.filter((o) => o.affordable !== false);

          // Nothing is spent from here. Every image and video ends in a card
          // -- model, quality, length, the exact price -- and only the
          // Generate button on it starts the job. Abel asked for exactly this:
          // be asked which model and which resolution, see the cost, confirm.
          // A model they named precisely is simply the one already selected.
          const preselect = job.only && job.settled
            ? choices.options[0]?.externalId
            : choices.auto?.externalId ?? affordable[0]?.externalId;
          // `total` is every model they have of this kind, so the card can
          // offer the rest: eight rows is a shortlist, not the catalogue.
          const offer = { ...choices, preselect, settings: job.settings, total: pool.length, withPicture };

          const money = affordable.length === 0 && credits
            ? ` None of these fit your ${credits} right now — topping up on ${pretty(door?.providerSlug) || "your provider"} would unlock them.`
            : credits
            ? ` You have ${credits}.`
            : "";
          speak(
            job.unmatched ? `I couldn't find "${job.named}" among your models. ` : "",
            job.only && job.settled
              ? `Ready to make ${job.prompt} with ${choices.options[0].label}. Pick the quality and tap Generate.`
              : job.only
              ? `More than one model matches "${job.named}". Pick one and tap Generate.`
              : `${job.intro ?? `Let's make ${job.prompt}.`} Pick a model and quality, then tap Generate.`,
            money,
          );
          // The request travels with the offer -- the SUBJECT, not the
          // sentence -- so Generate starts exactly this job, and a typed "use
          // Kling" afterwards still knows what to make and from what.
          send({ t: "models", capability: job.capability, choices: offer, request: job.prompt, references: job.references });
          await remember({
            kind: "models",
            choices: offer,
            request: job.prompt,
            references: job.references,
            settings: job.settings,
            source_artifact_id: job.sourceArtifactId ?? null,
          });
          return finish();
        };

        try {
          // A photo and nothing else. The picture is the message, so the reply
          // is what can be done with it -- as taps, since "animate it" is a
          // thing to offer rather than a thing to have to word.
          if (!asked.trim() && attachments.length > 0 && !body.action) {
            const many = attachments.length > 1;
            speak(
              many
                ? `Got the ${attachments.length} photos. I can animate from the first to the last, or work from them.`
                : "Got the photo. Want it animated, or changed?",
            );
            const options = many
              ? ["Animate from the first to the last", "Edit them: "]
              : ["Animate it", "Edit it: "];
            send({ t: "suggestions", options });
            await remember({ kind: "suggestions", options });
            return finish();
          }

          // A button said exactly what it wants. No router, no brand reading,
          // no trail about looking at openings -- none of that is what a tap on
          // "PDF" asked for.
          if (body.action) {
            const action = body.action;

            if (action.type === "export") {
              const { data } = await asUser.rpc("artifact", { p_id: action.artifactId });
              const source = (data ?? [])[0];
              if (!source) {
                speak("I can't find that any more.");
                await remember();
                return finish();
              }
              const format = ["docx", "pdf", "zip"].includes(action.format) ? action.format : "pdf";
              speak(`Making ${format === "zip" ? "a ZIP of everything" : `the ${format.toUpperCase()}`}.`);
              return await startRun("export", { artifact_id: source.id, format }, null);
            }

            if (action.type === "generate") {
              // Whatever kind the card was for -- pictures, video, music.
              const capability = (["image_generation", "audio_generation", "voice_generation"]
                  .includes(action.capability)
                ? action.capability
                : "video_generation") as Capability;
              const references = (action.references ?? [])
                .filter((path) => path.startsWith(`${auth.user!.id}/uploads/`) && !path.includes(".."))
                .map((path) => ({ path, kind: "image" }));
              // Settings asked for before the tap -- "2k" -- live on the offer
              // the tap answers, not on the button.
              const offer = await lastOffer();
              const same = offer !== null && offer.request === action.prompt;
              // What they asked for in words, then what they set on the card --
              // the card wins, it is the later and more exact of the two.
              const settings = {
                ...(same ? offer!.settings : {}),
                ...Object.fromEntries(
                  Object.entries(action.settings ?? {}).filter(([k, v]) =>
                    ["resolution", "duration", "aspect_ratio", "quality"].includes(k) &&
                    (typeof v === "string" || typeof v === "number")
                  ),
                ),
              };
              // An Animate offer's source travels on the offer, not the button.
              const source = same ? offer!.sourceArtifactId : null;
              speak(
                source
                  ? "Animating it."
                  : `Making ${action.prompt}.`,
              );
              const quoted = action.quoted && typeof action.quoted.amount === "number"
                ? { unit: String(action.quoted.unit ?? "credits"), amount: action.quoted.amount, quoted: true }
                : null;
              return await startRun("generate", {
                capability,
                prompt: action.prompt,
                model: action.model ?? null,
                settings,
                quoted_cost: quoted,
                references,
                ...(source ? { source_artifact_id: source } : {}),
              }, null);
            }

            if (action.type === "answers") {
              const answers = action.answers ?? {};

              // The one export question travels this way too.
              if (answers.format) {
                const source = await latestExportable();
                if (!source) {
                  speak("There's nothing in this conversation to export yet.");
                  await remember();
                  return finish();
                }
                const format = ["docx", "pdf", "zip"].includes(answers.format) ? answers.format : "pdf";
                speak(`Making ${format === "zip" ? "a ZIP of everything" : `the ${format.toUpperCase()}`} of "${source.title}".`);
                return await startRun("export", { artifact_id: source.id, format }, null);
              }

              const { data: brandRow } = await asUser
                .from("brands").select("id, name, niche, audience").limit(1).maybeSingle();
              if (!brandRow) {
                speak("Set up your brand first, under You, and I can plan for it.");
                await remember();
                return finish();
              }

              const cadence = Number.parseInt(answers.cadence ?? "", 10);
              // As the person: these are their answers, and the function
              // checks they are writing to their own brand.
              const { data: strategyId, error: recordError } = await asUser.rpc("record_answers", {
                p_brand: brandRow.id,
                p_thread: threadId,
                p_goal: answers.goal ?? null,
                p_appetite: answers.appetite ?? null,
                p_audience: answers.audience ?? null,
                p_cadence: Number.isFinite(cadence) ? cadence : null,
              });
              if (recordError || !strategyId) throw recordError ?? new Error("answers not recorded");

              send({ t: "step", kind: "reading", detail: "Saved your answers" });
              return await draftCampaign(
                brandRow,
                strategyId as string,
                action.request ?? "",
                Math.min(Math.max(Number(action.days) || 30, 1), 60),
              );
            }

            if (action.type === "animate") {
              const { data } = await asUser.rpc("artifact", { p_id: action.artifactId });
              const source = (data ?? [])[0];
              if (!source || source.kind !== "image") {
                speak("I can only animate an image.");
                await remember();
                return finish();
              }
              const prompt = action.prompt?.trim() ||
                `${String(source.body?.prompt ?? "this image")}, brought to life with subtle, natural motion`.trim();
              // Through the same picker as anything else made: priced, checked
              // against the balance, only models that take a starting picture.
              return await produce({
                capability: "video_generation",
                prompt,
                settings: {},
                references: [],
                sourceArtifactId: source.id,
                brandId: null,
                intro: "Here's what can animate it.",
              });
            }
          }

          // Read under RLS, as the user -- silently. These are database reads
          // measured in milliseconds, and announcing them on every message
          // ("Read what you've told me about…", "Looked at your last 15
          // openings") made the agent look like it was checking up on
          // somebody before answering "hi". Steps are for work a person would
          // want to watch: making something, pricing it, researching.
          const [pending, awaiting] = await Promise.all([lastOffer(), lastAwaiting()]);
          const context = [
            ...history.slice(0, -1).slice(-6).map((turn) =>
              `${turn.role === "user" ? "Person" : "Autocast"}: ${turn.content.replace(/\s+/g, " ").slice(0, 300)}`
            ),
            ...(pending
              ? [`(Autocast then offered ${nounFor(pending.capability)} models for: "${pending.request}")`]
              : []),
          ].join("\n");

          // What are they asking for -- read WITH the conversation, in
          // parallel with the reads it does not depend on.
          // The account state is read alongside, not after: it is only needed
          // for a plain reply, but waiting for the router before starting it
          // put seconds in front of the first word.
          const [routed, brandRead, recentRead, baseState] = await Promise.all([
            route(asked, OPENAI_KEY, context),
            asUser.from("brands").select("id, name, niche, audience").limit(1).maybeSingle(),
            asUser.from("posts").select("hook").order("created_at", { ascending: false }).limit(15),
            describeState(false),
          ]);
          const brand = brandRead.data as { id: string; name: string; niche: string; audience: string } | null;

          const { data: facts } = brand
            ? await asUser.from("brand_memory").select("fact").eq("brand_id", brand.id).limit(40)
            : { data: [] };
          const known = ((facts ?? []) as Array<{ fact: string }>).map((row) => row.fact).filter(Boolean);
          const previous = ((recentRead.data ?? []) as Array<{ hook: string }>).map((row) => row.hook).filter(Boolean);

          // The gate. A month of content is the single most expensive thing
          // this product does, and the worst version of it is a month built
          // against the wrong goal -- so it does not start until the goal is
          // known and a person has agreed to it.
          //
          // Only what is genuinely missing is asked. `brand_knowledge` reports
          // what the database already holds, and a question somebody already
          // answered during setup is the fastest way to feel stupid.
          // Somebody asked for something to be made. Before anything is
          // spent, find out what can actually make it -- and say so with the
          // real constraints, because "Sora 2" means nothing next to "720p
          // only, 4/8/12 seconds".
          //
          // The gate is `worthAsking`, not "are there options". One model is
          // not a choice, and several that differ in nothing a person can act
          // on is a list of names -- asking somebody to rank names they have
          // no basis to rank is how a product turns into paperwork. When it is
          // not worth asking, Auto has already decided and the work starts.
          // Research is long work and goes to the worker. Said up front that it
          // takes minutes and survives the app closing, because a person who
          // expects an instant answer and gets a card is confused, and one who
          // was told is not.
          if (routed.intent === "research") {
            speak(
              "I'll look into that properly — a few questions, each answered, then pulled together. ",
              "It takes a few minutes and keeps going if you close the app.",
            );
            return await startRun("research", { topic: asked }, brand?.id ?? null);
          }

          if (routed.intent === "export") {
            const source = await latestExportable();
            const made = await madeHere();

            // "Export everything" means everything: the pictures, the videos,
            // the music and the documents from this conversation in one ZIP.
            // Asked for by name, or the only thing that makes sense when
            // nothing here is a document.
            const wantsAll = /\b(everything|all of (it|them)|all the|whole (chat|conversation)|both)\b/i.test(asked);
            if (made.length > 0 && (wantsAll || !source)) {
              speak(
                `Packing up everything from this chat — ${made.length} file${made.length === 1 ? "" : "s"}.`,
              );
              return await startRun("export", { thread_id: threadId, format: "zip", everything: true }, null);
            }

            if (!source) {
              speak("There's nothing in this conversation to export yet. Ask me to research something, plan a month, or make something, and I can turn it into a file.");
              await remember();
              return finish();
            }

            if (!routed.format) {
              // The one question that changes the file. Asked with buttons.
              // Worded so the tapped answer reads "Export it as PDF" -- which is
              // what goes back through the router, and it must read as an
              // export with a format, not as a question about files.
              const questions = [{
                key: "format",
                prompt: "Export it as",
                options: [
                  { value: "docx", label: "Word document" },
                  { value: "pdf", label: "PDF" },
                  { value: "zip", label: "ZIP with everything" },
                ],
                allowsFreeText: false,
              }];
              speak(`I can export "${source.title}". `);
              send({ t: "questions", questions });
              await remember({ kind: "questions", questions });
              return finish();
            }

            speak(`Making ${routed.format === "zip" ? "a ZIP of everything" : `the ${routed.format.toUpperCase()}`} of "${source.title}".`);
            return await startRun("export", { artifact_id: source.id, format: routed.format }, null);
          }

          // A named model means something is being made, even when the words
          // around it ("use nano banana pro2 with 2k resolution") read as chat.
          // An answer to "what should it be of?" continues that request, even
          // though "a cup of tea" on its own reads as chat.
          const continuing = awaiting !== null && (routed.intent === "make" || routed.intent === "chat");

          if (routed.intent === "make" || routed.model || continuing) {
            const namedModel = routed.model ?? awaiting?.model ?? null;

            // A picture they sent themselves, in this turn or the one just
            // before it -- "animate it" a message after uploading is still
            // about that photo.
            const theirs = attachments.length > 0 ? attachments : await recentAttachments();
            const wantsMotion = /\banimat|bring (it|this|that)? ?to life|make (it|this|that) move/i.test(asked);

            // Typed "animate this" means the last picture made here, the same
            // as the Animate button under it -- unless they brought their own,
            // which is the picture they mean.
            let sourceArtifactId = pending?.sourceArtifactId ?? null;
            let animating = "";
            if (theirs.length > 0 && wantsMotion && !pending?.sourceArtifactId) {
              animating = "brought to life with subtle, natural motion";
            } else if (!sourceArtifactId && wantsMotion && threadId) {
              const { data } = await asUser.rpc("thread_artifacts", { p_thread: threadId });
              const image = ((data ?? []) as Array<{ id: string; kind: string; body: Record<string, unknown> }>)
                .find((row) => row.kind === "image");
              if (image) {
                sourceArtifactId = image.id;
                animating = `${String(image.body?.prompt ?? "this image")}, brought to life with subtle, natural motion`;
              }
            }

            // WHAT to make: the subject the router pulled out, the reply to
            // "what should it be of?", or what the last offer was for. Never
            // the instruction sentence -- "use nano banana pro with 2k" sent as
            // a prompt came back as a drawing of a handheld console labelled
            // NANO BANANA PRO 2K.
            // The reply itself counts only when it carries nothing else: "use
            // nano banana pro at 2k" answering the question is a model, not a
            // subject. A bare kind ("an image") is never one -- that went out
            // as the whole prompt and came back as a street nobody asked for.
            const answered = continuing && !routed.model && Object.keys(routed.settings).length === 0 &&
                !vagueSubject(asked)
              ? asked.trim()
              : "";
            const offeredFor = pending?.request && !vagueSubject(pending.request) ? pending.request : "";
            const subject = routed.subject?.trim() || answered;
            let prompt = subject || offeredFor || animating;
            // Animating: the prompt is the MOTION, never a phrase pointing back
            // at the picture. "animate this photo" came back from the router as
            // the subject "the photo they want to animate", which would have
            // gone to Kling as the whole prompt.
            if (animating) {
              const motion = subject && !pointsAtIt(subject) ? subject : "";
              prompt = motion ? `${motion}, ${animating}` : animating;
            }
            // Asked what, and told "surprise me": theirs to leave to us.
            if (!prompt && continuing && leftToUs(asked)) prompt = "a striking, beautifully composed scene";
            const settings = { ...(awaiting?.settings ?? {}), ...(pending?.settings ?? {}), ...routed.settings };
            const references = attachments.length > 0
              ? attachments
              : (pending?.references ?? awaiting?.references ?? (wantsMotion ? theirs : []));

            // Which kind: a model they named settles it, then what they said,
            // then what they were already making, then video.
            const KINDS = ["image_generation", "video_generation", "audio_generation"] as const;
            const earlier = awaiting?.capability ?? pending?.capability;
            const saidKind: Capability | null = animating
              ? "video_generation"
              : routed.media === "image"
              ? "image_generation"
              : routed.media === "audio"
              ? "audio_generation"
              : routed.media === "video"
              ? "video_generation"
              : null;
            let capability: Capability = saidKind ??
              (KINDS.includes(earlier as typeof KINDS[number]) ? earlier as Capability : "video_generation");

            // A name is looked up across EVERYTHING they have, not the eight
            // on screen -- "nano banana pro" was not in the first eight image
            // models, and was answered with a list of video models instead.
            let only: string[] | undefined;
            let unmatched = false;
            let settled = false;
            let namedLabel: string | null = null;
            if (namedModel) {
              const pools = await Promise.all(
                KINDS.map(async (cap) =>
                  (await candidatesFor(admin, auth.user!.id, cap)).map((c) => ({ ...c, capability: cap as Capability }))
                ),
              );
              const matches = matchModels(pools.flat(), namedModel);
              if (matches.length > 0) {
                // A name can span kinds -- Higgsfield has three Kling video
                // models and a Kling image one. The kind comes from what they
                // said, then from what they were already making, then from
                // where most of the matches are.
                const kinds = new Set(matches.map((m) => m.capability));
                const said = saidKind;
                const offered = earlier && kinds.has(earlier as Capability)
                  ? earlier as Capability
                  : null;
                capability = said && kinds.has(said)
                  ? said
                  : offered ?? [...kinds].sort((a, b) =>
                    matches.filter((m) => m.capability === b).length - matches.filter((m) => m.capability === a).length
                  )[0];

                const same = matches.filter((m) => m.capability === capability).slice(0, 4);
                const exact = settlesOn(same, namedModel);
                // Started without asking only when nothing about it is a
                // guess: one model, and the kind either certain or said.
                settled = exact !== null && (kinds.size === 1 || said !== null || offered !== null);
                only = settled && exact ? [exact.externalId] : same.map((m) => m.externalId);
                namedLabel = settled && exact ? exact.label : null;
              } else {
                unmatched = true;
              }
            }

            // Nothing to make yet: a model or a setting, but not the thing.
            // One question, and the model and settings wait with it.
            if (!prompt && !sourceArtifactId) {
              const noun = nounFor(capability);
              const chosen = [
                namedLabel ?? namedModel,
                typeof settings.resolution === "string" ? settings.resolution.toUpperCase() : null,
              ].filter(Boolean).join(" at ");
              speak(chosen ? `Sure — ${chosen}. What should the ${noun} be of?` : `Sure — what should the ${noun} be of?`);
              await remember({ kind: "awaiting_subject", capability, model: namedModel, settings, references });
              return finish();
            }

            return await produce({
              capability,
              prompt,
              settings,
              references,
              // Answering an offer that was for animating something, or saying
              // "animate this", animates that thing.
              sourceArtifactId,
              only,
              settled,
              unmatched,
              named: namedModel,
              brandId: brand?.id ?? null,
            });
          }

          if (routed.intent === "plan" && brand) {
            const { data: knowledgeRows } = await asUser
              .rpc("brand_knowledge", { p_brand: brand.id });
            const known = (knowledgeRows ?? [])[0];

            if (known) {
              const { data: strategyRow } = known.strategy_id
                ? await asUser
                  .from("strategies")
                  .select("goal, appetite, audience, cadence")
                  .eq("id", known.strategy_id)
                  .maybeSingle()
                : { data: null };

              const questions = missingForPlan(known, strategyRow);

              // Everything it needs is already known, so nothing is asked --
              // straight to the strategy card, which is still a confirmation.
              if (questions.length === 0) {
                let strategyId = known.strategy_id as string | null;
                if (!strategyId) {
                  const { data } = await asUser.rpc("record_answers", { p_brand: brand.id, p_thread: threadId });
                  strategyId = data as string;
                }
                return await draftCampaign(brand, strategyId, asked, routed.days ?? 30);
              }

              if (questions.length > 0) {
                send({
                  t: "step",
                  kind: "reading",
                  detail: `Checked what I already know about ${brand.name}`,
                });

                const count = questions.length === 1 ? "one thing" : `${questions.length} things`;
                for (const chunk of [
                  `I can plan ${routed.days ?? 30} days for ${brand.name}. `,
                  `Before I build it I need ${count} from you — `,
                  "everything else I already have.",
                ]) {
                  said += chunk;
                  send({ t: "delta", v: chunk });
                }

                // Rendered as taps by the app. Sent as data rather than as a
                // numbered list in the prose, because the answers come back as
                // values and parsing them out of a sentence is how the wrong
                // month gets built. The request and length travel with them,
                // so the answers can go straight on to the strategy.
                const days = routed.days ?? 30;
                send({ t: "questions", questions, request: asked, days });
                // The questions go into the transcript with the turn, so
                // reopening the thread shows what was asked rather than a
                // sentence promising questions that are no longer there.
                await remember({ kind: "questions", questions, request: asked, days });
                send({ t: "done" });
                controller.close();
                return;
              }
            }
          }

          // The voice. Written after Abel called the old one "boring, 0%
          // understanding" -- fairly: its own worked example answered "how's it
          // going" with "Fine. What do you want to work on?", and it answered
          // "so do I have to top up?" with "I don't handle payments" while
          // knowing the last job had just failed for want of credits.
          //
          // The conversational technique is borrowed from Anthropic's Fable
          // system prompt (warm and direct, answer before asking, at most one
          // question, minimal formatting in casual chat, no filler, after doing
          // something say the result) -- rewritten for this product rather than
          // pasted, since most of that prompt is tooling that does not exist
          // here. The honesty rules are this product's own and stay: see
          // planner-invents-facts. Examples use a fictional brand, Kettle, so
          // nothing in them can be quoted back as a fact about the real one.
          const system = `<autocast>
You are Autocast, the content partner inside the Autocast app. You help one
person grow their social account: you talk ideas through, write hooks and
captions, research, plan campaigns, and make images and videos with the
generator they connected. You are talking to the owner of the account.

<how_you_talk>
Warm, sharp and direct -- like a friend who happens to be very good at content.
Treat them as a capable adult.
Answer what they actually asked, first, in plain words. For simple things one to
three sentences is right; offer to go further when it would help.
Match their energy. A casual message gets a casual reply with no headings, no
bullet points and no bold -- just talk. Use a short list only when the answer
really is several separate things.
Every sentence adds something. No openers like "Great question", "Absolutely",
"I'd be happy to"; never "honestly", "genuinely" or "straightforward"; no hype
words ("unlock", "game-changer", "supercharge").
When a request is ambiguous, take the most sensible reading and act on it. Ask at
most one short question, and only when the answer would change what you do.
When something went wrong, say what happened and what to do about it, with the
real numbers from STATE -- never a vague brush-off.
Do not narrate your own process ("I checked your account", "let me look"). Just
answer.
</how_you_talk>

<this_app>
Tell people how to do things here, concretely, when it helps:
- Make an image or a video: just ask ("make an image of...", "a 5 second video
  of..."). They'll see models with real prices from their own account, and can
  tap one or let you choose. Naming a model ("with nano banana 2") uses it.
- Animate an image: the Animate button under any image you made.
- Research: "research ..." runs in the background for a few minutes and comes
  back as a report they can read and export.
- Export: "export that as PDF / Word / ZIP", or the Export button on a report or
  campaign.
- Campaigns: "plan a two-week launch campaign for ...". You ask two or three
  questions with buttons, show a strategy card, and write the posts once they
  approve it.
- Attach a photo: the + button, then Attach a photo; ask about it or use it as a
  reference.
- Autopilot: the card on Home. It makes each day's video ahead of time; nothing
  is posted until they approve it.
- Connections: + then Connections, or the You tab. Disconnect is in the ... menu.
Generation is paid for with credits on THEIR generator account (Higgsfield), not
by Autocast. Topping up happens on higgsfield.ai.
</this_app>

<state>
The STATE block in the next message is the live truth about their account: what
is connected, what you recently made or tried to make in this conversation and
how it ended, prices you have seen, and their credit balance when it was
checked. Use it. If they ask whether they need to top up, answer from it with
the actual numbers, and suggest the cheaper option that would work.
</state>

<honesty>
Everything you may treat as true about their brand is in FACTS. Nothing else is
known about it, and you never fill the gap:
- Never announce product changes ("this week we added...", "now with...").
- Never invent a person or their words: no testimonials, reviews, "a customer
  said", "people keep asking".
- Never invent a number about the account: users, sales, ratings, dates, streaks.
If what they asked for needs one of these, say which fact you need.
You cannot publish or approve anything, and never imply you did. Everything that
reaches TikTok goes through the approval sheet, which is them tapping a button.
</honesty>

<examples>
These are about a DIFFERENT, fictional account called Kettle, which sells loose
leaf tea. Nothing in them is true of the real account. They show the shape of a
good answer only.

<example>
<user>how's it going</user>
<good>Good! Ready when you are. Want to make something for Kettle today, or talk
through ideas for the week?</good>
<bad>Fine. What do you want to work on?</bad>
</example>

<example>
<state>Higgsfield connected. Last video: Cinema Studio Video 3.0, quoted 75
credits, failed: not enough credits. Balance: 26.02 credits. Prices seen:
Cinema Studio Video 18 credits, Soul 2.0 image 0.12 credits.</state>
<user>so do I have to top up or what?</user>
<good>Not necessarily. That video model needed 75 credits and you have 26, so it
couldn't run -- but Cinema Studio Video is 18 and would fit. Want me to animate
it with that instead? Topping up on higgsfield.ai only matters if you want the
bigger models.</good>
<bad>I don't handle payments or credits. You'd need to check with your provider.</bad>
</example>

<example>
<facts>Kettle sells loose leaf tea. Every order is packed the morning it ships.</facts>
<user>Give me a hook about people loving it.</user>
<good>I don't have anything from customers I can quote, so I'd use something true
instead: "Packed the morning it ships." It's a real difference and it argues for
itself.</good>
<bad>"One customer told me Kettle is the best tea they've ever had."</bad>
</example>
</examples>
</autocast>`;

          const brief = brand
            ? `Account: ${brand.name}. Subject: ${brand.niche || "not stated"}. Audience: ${brand.audience || "not stated"}.`
            : "The account has not described itself yet.";

          const factBlock = known.length > 0
            ? `FACTS:\n${known.map((fact) => `- ${fact}`).join("\n")}`
            : "FACTS: none recorded yet. You know only the account line above. Say so when it matters, and suggest adding facts under Brand.";

          const avoid = previous.length > 0
            ? `Openings already used, do not repeat them:\n${previous.map((hook) => `- ${hook}`).join("\n")}`
            : "";

          const stateBlock = routed.aboutCredits ? `${baseState}\n${await balanceLine()}` : baseState;

          // Attached pictures go to the model as image data on the last turn,
          // so "write a caption for this" is about this picture. Sent as bytes
          // rather than as a signed link: a link carries a token, and nothing
          // that grants access belongs in what a model reads.
          const pictures: Array<{ type: "image_url"; image_url: { url: string } }> = [];
          for (const path of attachments) {
            const { data: file } = await admin.storage.from("artifacts").download(path);
            if (!file || !/^image\//.test(file.type) || file.size > 8 * 1024 * 1024) continue;
            const bytes = new Uint8Array(await file.arrayBuffer());
            let binary = "";
            for (let i = 0; i < bytes.length; i += 0x8000) {
              binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
            }
            pictures.push({ type: "image_url", image_url: { url: `data:${file.type};base64,${btoa(binary)}` } });
          }
          if (pictures.length > 0) {
            send({ t: "step", kind: "reading", detail: pictures.length === 1 ? "Looking at your picture" : `Looking at your ${pictures.length} pictures` });
          }

          const turns = history.map((turn, index) =>
            index === history.length - 1 && pictures.length > 0
              ? { role: turn.role, content: [{ type: "text", text: turn.content }, ...pictures] }
              : turn
          );

          const upstream = await fetch("https://api.openai.com/v1/chat/completions", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${OPENAI_KEY}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: MODEL,
              stream: true,
              messages: [
                { role: "system", content: system },
                { role: "system", content: [brief, factBlock, stateBlock, avoid].filter(Boolean).join("\n\n") },
                ...turns,
              ],
            }),
          });

          if (!upstream.ok || !upstream.body) {
            const detail = await upstream.text().catch(() => "");
            console.error("openai", upstream.status, detail.slice(0, 400));
            send({ t: "error", message: "The writer could not be reached just now." });
            controller.close();
            return;
          }

          // OpenAI's own SSE, unwrapped and re-emitted in our shape. Passing it
          // through raw would tie the app to their event format, and the app
          // already has to understand ours for the steps.
          const reader = upstream.body.getReader();
          const decoder = new TextDecoder();
          let buffer = "";
          let wrote = false;

          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });

            // Frames are separated by a blank line; a partial one stays in the
            // buffer until the rest of it arrives.
            const frames = buffer.split("\n\n");
            buffer = frames.pop() ?? "";

            for (const frame of frames) {
              const line = frame.split("\n").find((part) => part.startsWith("data: "));
              if (!line) continue;
              const payload = line.slice(6).trim();
              if (payload === "[DONE]") continue;
              try {
                const parsed = JSON.parse(payload);
                const delta = parsed?.choices?.[0]?.delta?.content;
                if (typeof delta === "string" && delta.length > 0) {
                  wrote = true;
                  said += delta;
                  send({ t: "delta", v: delta });
                }
              } catch {
                // A frame that will not parse is one frame of one reply. Losing
                // it is better than ending the stream over it.
              }
            }
          }

          if (!wrote) {
            send({ t: "error", message: "Nothing came back. Try rephrasing." });
          }
          await remember();
          send({ t: "done" });
          controller.close();
        } catch (thrown) {
          console.error("agent-chat", thrown);
          // Whatever was written before it broke is still kept. A person who
          // watched half an answer arrive and then reopens the thread should
          // find that half, not a gap -- and the client already showed it.
          await remember();
          send({ t: "error", message: "Something went wrong writing that." });
          controller.close();
        }
      },
    });

    return new Response(stream, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (error) {
    return fail(error);
  }
});
