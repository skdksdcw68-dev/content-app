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
import { balanceFor, candidatesFor, oneEach } from "../_shared/connectors/route.ts";
import type { Capability } from "../_shared/connectors/contract.ts";
import { rediscover } from "../_shared/connectors/discovery.ts";
import { type Charge, chargeForGeneration, refundCredits, requireUsage, usageLine } from "../_shared/credits.ts";
import { recordUsage } from "../_shared/usage.ts";
import { write as writeWithClaude, writeStreaming } from "../_shared/writer.ts";
import { parseStoryCommand } from "../_shared/video/command.ts";
import { makeBrief, type VideoBrief } from "../_shared/video/brief.ts";
import { productionFor } from "../_shared/video/style.ts";

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
// The chat tier, not the deep one: replies were the whole AI bill and read
// no differently on the smaller model (Abel, 23 Sep 2026: "reduce our cost
// from AI"). Strategy drafting below still uses MODELS.deep, where depth
// is the point.
const MODEL = MODELS.chat;

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
  | { type: "answers"; answers: Record<string, string>; request?: string; days?: number }
  /** "Photo video" on the create card: the story engine, with the choices
   *  made on the card instead of a typed `/story` command. */
  | {
    type: "story";
    topic: string;
    style: string;
    seconds?: number;
    narration?: boolean;
    /** The chosen look's prompt (CategoryLooks), as the writer reads it. */
    look?: string;
    voiceId?: string;
    captionStyle?: string;
    /** What the brief read from the request and any pictures sent: tone, pace,
     *  structure. Told to the writer after the topic. */
    direction?: string;
  };

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
  /** The turn was a tap -- a suggestion chip -- not something typed. Stored
   *  marked, like every action, so a reopened conversation does not show a
   *  sentence the person never wrote. */
  tap?: boolean;
  /** What they set once in the generator's settings (the sliders in the bar):
   *  the model, how many, the shape, the quality, a video's length. */
  prefs?: { image?: GeneratorPref; video?: GeneratorPref };
}

interface GeneratorPref {
  model?: string;
  count?: number;
  aspect_ratio?: string;
  resolution?: string;
  quality?: string;
  duration?: number;
}

/**
 * Three short follow-ups for a picture request -- "in winter colours", "on a
 * model outdoors", "turn it into a 5-second video" -- shown under the result as
 * one-tap remixes, the way Grok does. Empty on any failure: they are a nicety.
 */
async function remixIdeas(
  prompt: string,
  onUsage?: (model: string, usage: { prompt_tokens?: number; completion_tokens?: number } | null) => Promise<void>,
): Promise<string[]> {
  try {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${OPENAI_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: MODELS.chat,
        response_format: { type: "json_object" },
        max_tokens: 120,
        messages: [
          {
            role: "system",
            content: "Suggest three short follow-ups someone might tap after getting pictures made from the request: " +
              "one changing the style, one changing the subject or setting, and one turning it into a short video. " +
              "Each 2 to 6 words, lowercase, no full stop, an instruction that makes sense on its own after the request " +
              '("in winter colours", "on a model outdoors", "turn it into a 5-second video"). JSON only: {"ideas":[string,string,string]}',
          },
          { role: "user", content: prompt.slice(0, 400) },
        ],
      }),
    });
    if (!response.ok) return [];
    const body = await response.json();
    await onUsage?.(body.model ?? MODELS.chat, body.usage ?? null).catch(() => {});
    const ideas = JSON.parse(body.choices?.[0]?.message?.content ?? "{}").ideas;
    return Array.isArray(ideas)
      ? ideas.filter((idea: unknown) => typeof idea === "string" && idea.trim()).map((idea: string) => idea.trim().slice(0, 60)).slice(0, 3)
      : [];
  } catch {
    return [];
  }
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

    // Chat draws on the same monthly meter as everything else (0079): the
    // reply's real cost is taken from its tokens once it is written. Here it
    // is only refused when the month is already used up.
    await requireUsage(createClient(SUPABASE_URL, SERVICE_KEY), auth.user.id);

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

    // Which app this conversation is about. Several are the point -- he runs
    // marketing for all of them -- so the one on screen travels with every
    // message rather than the server guessing at the oldest.
    const brandWanted = typeof body.brandId === "string" && body.brandId.length === 36 ? body.brandId : null;

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
      // A button or a chip is not a sentence the person wrote. Its text is
      // kept for the model's context, marked so the app never shows it as a
      // bubble (Netro, 31 Oct 2026: "when they hit, it sends the text for
      // itself... instead, it will do it in the background").
      const tapped = Boolean(body.action) || body.tap === true;
      // The app sends a message again when the first try said nothing for 20
      // seconds (a connection gone stale under it). If that first try did
      // arrive after all, its turn is already stored, and storing it twice
      // would answer the same message twice.
      let stored = false;
      if (request.headers.get("x-autocast-retry") === "1") {
        const { data: last } = await admin.from("messages").select("role, text")
          .eq("thread_id", threadId).order("seq", { ascending: false }).limit(1).maybeSingle();
        stored = last?.role === "user" && last?.text === asked;
      }
      const { error: sayError } = stored ? { error: null } : await asUser.rpc("append_message", {
        p_thread: threadId,
        p_role: "user",
        p_text: asked,
        // Kept with the turn so a reopened conversation still shows what was
        // attached, not a message referring to a picture that is not there.
        ...(attachments.length > 0
          ? { p_render_hint: { kind: "attachments", paths: attachments } }
          : tapped ? { p_render_hint: { kind: "tap" } } : {}),
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
        const startRun = async (
          kind: string,
          input: Record<string, unknown>,
          brandId: string | null,
          /** Spoken once the run is certain to start -- after the credits. */
          announce?: string,
        ) => {
          // 🔴 Making something is paid for in credits, BEFORE it starts and only
          // when it runs on our money (`_shared/credits.ts`). This one line is
          // every road to a generation: the card's Generate button, the
          // composer's send-is-generate, an answered question, a direct ask.
          // Until 29 Sep none of them were counted at all.
          let charge: Charge | null = null;
          if (kind === "generate") {
            try {
              charge = await chargeForGeneration(admin, auth.user!.id, input);
            } catch (thrown) {
              // Not enough credits, or a model for a higher plan: said in the
              // conversation, in words, and the app is told to offer the plans.
              if (thrown instanceof PublicError && thrown.status === 402) {
                speak(thrown.message);
                send({ t: "paywall", code: thrown.failureCode ?? "needs_credits" });
                await remember();
                finish();
                return;
              }
              throw thrown;
            }
          }
          if (announce) speak(announce);

          const { data: runId, error } = await admin.rpc("start_agent_run", {
            p_user: auth.user!.id,
            p_thread: threadId,
            p_kind: kind,
            // The reference travels on the run, so a failure -- by any road --
            // can give the credits back (migration 0077's trigger) and a
            // success can settle them to what the provider charged.
            p_input: charge ? { ...input, credit_ref: charge.ref, credits: charge.credits } : input,
            p_brand: brandId,
            p_model: MODELS.chat,
          });
          if (error || !runId) {
            if (charge) await refundCredits(admin, auth.user!.id, charge.ref);
            throw error ?? new Error("the run did not start");
          }
          send({ t: "run", id: runId, kind });
          kickWorker();
          await remember({ kind: "run", run_id: runId, run_kind: kind });
          finish();
        };

        /** Starts the worker NOW instead of waiting for the next minute's tick
         *  (Netro, 19 Oct 2026: research "slower than Sage"). Safe next to the
         *  cron: due_agent_runs leases what it takes, so nobody runs a step twice. */
        const kickWorker = () => {
          const cronSecret = Deno.env.get("CRON_SECRET");
          if (!cronSecret) return;
          const kick = fetch(`${SUPABASE_URL}/functions/v1/run-agent-jobs`, {
            method: "POST",
            headers: { "x-cron-secret": cronSecret, "Content-Type": "application/json" },
            body: "{}",
          }).catch(() => {});
          (globalThis as { EdgeRuntime?: { waitUntil?: (p: Promise<unknown>) => void } }).EdgeRuntime?.waitUntil?.(kick);
        };

        /**
         * Several pictures from one request, each its own run.
         *
         * Abel, 1 Nov 2026: "When you ask it to create or generate 4 different
         * images or 10 images, it actually generates a split image on a single
         * photo." One job was sent "4 different images..." and the model drew
         * one picture cut into four. Now each picture is its own job, told to
         * be one picture, so every provider can do it and each is charged and
         * refunded on its own. They share a batch id, so the conversation draws
         * them together.
         *
         * Every charge is taken before any run starts: half a set started and
         * then refused for the plan is worse than none.
         */
        const startBatch = async (count: number, input: Record<string, unknown>, announce: string) => {
          const charges: Array<Charge | null> = [];
          for (let i = 0; i < count; i++) {
            try {
              charges.push(await chargeForGeneration(admin, auth.user!.id, input));
            } catch (thrown) {
              for (const charge of charges) if (charge) await refundCredits(admin, auth.user!.id, charge.ref);
              if (thrown instanceof PublicError && thrown.status === 402) {
                speak(thrown.message);
                send({ t: "paywall", code: thrown.failureCode ?? "needs_credits" });
                await remember();
                finish();
                return;
              }
              throw thrown;
            }
          }
          speak(announce);

          const batch = crypto.randomUUID();
          const ids: string[] = [];
          for (const [index, charge] of charges.entries()) {
            const { data: runId, error } = await admin.rpc("start_agent_run", {
              p_user: auth.user!.id,
              p_thread: threadId,
              p_kind: "generate",
              p_input: {
                ...input,
                batch: { id: batch, index, of: count },
                ...(charge ? { credit_ref: charge.ref, credits: charge.credits } : {}),
              },
              p_brand: null,
              p_model: MODELS.chat,
            });
            if (error || !runId) {
              if (charge) await refundCredits(admin, auth.user!.id, charge.ref);
              continue;
            }
            ids.push(runId as string);
          }
          if (ids.length === 0) throw new Error("the runs did not start");

          send({ t: "run", id: ids[0], kind: "generate", ids });
          kickWorker();
          await remember({ kind: "run", run_id: ids[0], run_ids: ids, run_kind: "generate" });
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

          // Claude Sonnet 5.5 designs the strategy (19 Oct 2026), thinking at
          // medium; OpenAI if it cannot.
          const completion = await writeWithClaude({
              json: true,
              effort: "medium",
              openaiModel: MODELS.deep,
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
          });
          await recordUsage(admin, { userId: auth.user!.id, brandId: brand.id, kind: "campaign_write", model: completion.model ?? MODELS.deep, usage: completion.usage });
          const drafted = JSON.parse(completion.choices?.[0]?.message?.content ?? "{}");

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
          // Abel, 1 Nov 2026: he asked for four images like an outfit he had
          // sent; the card's Generate answered "Pictures are part of Autocast
          // Pro"; he subscribed and typed "try again with gpt 2 image" -- and
          // the picture he sent was gone, so the model drew flowers. Only the
          // very last assistant message was read, and that note was it. A plain
          // note in between (a paywall, a chat answer) does not end the offer;
          // something made, or a question asked, does. Recent only: an offer
          // from yesterday is not what "use Kling" answers.
          const { data } = await admin
            .from("messages")
            .select("render_hint, created_at")
            .eq("thread_id", threadId)
            .eq("role", "assistant")
            .gt("created_at", new Date(Date.now() - 30 * 60_000).toISOString())
            .order("seq", { ascending: false })
            .limit(6);
          let hint: Record<string, unknown> | null = null;
          for (const row of (data ?? []) as Array<{ render_hint: Record<string, unknown> | null }>) {
            const kind = row.render_hint?.kind;
            if (kind === "models") {
              hint = row.render_hint;
              break;
            }
            if (kind === "artifact" || kind === "run" || kind === "questions" || kind === "awaiting_subject") break;
          }
          if (!hint) return null;
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

        /**
         * Uploaded pictures as image data for a model to read. Sent as bytes
         * rather than as a signed link: a link carries a token, and nothing
         * that grants access belongs in what a model reads. Anything that is
         * not a picture, or is over 8 MB, is skipped.
         */
        const loadPictures = async (paths: string[]): Promise<Array<{ type: "image_url"; image_url: { url: string } }>> => {
          const pictures: Array<{ type: "image_url"; image_url: { url: string } }> = [];
          for (const path of paths) {
            const { data: file } = await admin.storage.from("artifacts").download(path);
            if (!file || !/^image\//.test(file.type) || file.size > 8 * 1024 * 1024) continue;
            const bytes = new Uint8Array(await file.arrayBuffer());
            let binary = "";
            for (let i = 0; i < bytes.length; i += 0x8000) {
              binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
            }
            pictures.push({ type: "image_url", image_url: { url: `data:${file.type};base64,${btoa(binary)}` } });
          }
          return pictures;
        };

        /**
         * A reference, resolved and owner-checked.
         *
         * Two kinds travel through the chat: a picture they uploaded, as its
         * path, and something made here, as `artifact:<id>`. The second is
         * what "put that music on the video" is made of, and it is resolved
         * here rather than trusted from the client -- an id is not permission.
         */
        const resolveReferences = async (refs: string[]): Promise<Array<{ path: string; kind: string }>> => {
          const out: Array<{ path: string; kind: string }> = [];
          const ids: string[] = [];
          for (const ref of refs.slice(0, 4)) {
            if (ref.startsWith("artifact:")) {
              ids.push(ref.slice("artifact:".length));
            } else if (ref.startsWith(`${auth.user!.id}/uploads/`) && !ref.includes("..")) {
              // Uploads are always JPEG: the app converts before it sends.
              out.push({ path: ref, kind: "image" });
            }
          }
          if (ids.length > 0) {
            const { data } = await admin
              .from("artifacts")
              .select("id, kind, storage_path")
              .eq("user_id", auth.user!.id)
              .in("id", ids);
            const rows = (data ?? []) as Array<{ id: string; kind: string; storage_path: string | null }>;
            // In the order they were offered: the first picture is the first
            // frame, the video comes before the track.
            for (const id of ids) {
              const row = rows.find((r) => r.id === id);
              if (row?.storage_path) out.push({ path: row.storage_path, kind: row.kind });
            }
          }
          return out;
        };

        /** What a request brings with it, as `suits` needs to hear it. */
        const bringsOf = async (refs: string[], source?: string | null) => {
          const resolved = await resolveReferences(source ? [...refs, `artifact:${source}`] : refs);
          return {
            image: resolved.some((r) => r.kind === "image"),
            video: resolved.some((r) => r.kind === "video"),
            audio: resolved.some((r) => r.kind === "audio"),
          };
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
            lines.push("Connected: nothing of their own. Not needed: Autocast's own models make pictures and videos.");
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

        /**
         * Their TikTok and their work, as lines of STATE.
         *
         * Without this, "my last post on tiktok" got "I don't have access to
         * your TikTok analytics" and "how many images did we make" got "no
         * record" -- both false, because plain chat was never shown either.
         * Abel's word for it was dumb. Cheap reads, all under RLS.
         */
        const accountLines = async (brandId: string | null): Promise<string> => {
          const [libraryRead, handleRead, madeRead] = await Promise.all([
            brandId ? asUser.rpc("library_videos", { p_brand: brandId }) : Promise.resolve({ data: null }),
            brandId
              ? asUser.from("platform_connections").select("username, platform").eq("brand_id", brandId).eq("status", "active").limit(1)
              : Promise.resolve({ data: [] as unknown[] }),
            asUser.from("artifacts").select("kind").limit(2000),
          ]);

          const lines: string[] = ["ACCOUNT:"];
          const handle = ((handleRead.data ?? []) as Array<{ username: string; platform: string }>)[0];
          // deno-lint-ignore no-explicit-any
          const library = libraryRead.data as Record<string, any> | null;
          if (!handle) {
            lines.push("No TikTok account is connected for this app yet.");
          } else {
            const account = library?.account ?? {};
            const count = (n: unknown) => (typeof n === "number" ? n.toLocaleString("en-US") : "unknown");
            lines.push(
              `TikTok @${handle.username}: ${count(account.followers)} followers, ${count(account.likes)} total likes, ` +
                `${count(account.video_count)} public videos. Autocast reads these every 6 hours. It cannot see private ` +
                `videos, drafts, or when the account was created.`,
            );
            // deno-lint-ignore no-explicit-any
            const videos = ((library?.videos ?? []) as Array<Record<string, any>>).slice(0, 6);
            if (videos.length > 0) {
              lines.push("Their latest public videos, newest first:");
              for (const v of videos) {
                const posted = v.posted_at ? new Date(v.posted_at).toLocaleDateString("en-GB", { day: "numeric", month: "short" }) : "date unknown";
                const rate = v.views > 0 ? `${(((v.likes + v.comments + v.shares) / v.views) * 100).toFixed(1)}% engagement` : "no views yet";
                lines.push(
                  `- "${String(v.title ?? "Untitled").slice(0, 70)}" posted ${posted}: ${v.views} views, ${v.likes} likes, ` +
                    `${v.comments} comments, ${v.shares} shares (${rate})${v.from_autocast ? ", posted with Autocast" : ""}`,
                );
              }
            }
          }

          const kinds = new Map<string, number>();
          for (const row of (madeRead.data ?? []) as Array<{ kind: string }>) {
            kinds.set(row.kind, (kinds.get(row.kind) ?? 0) + 1);
          }
          lines.push(
            kinds.size === 0
              ? "Made with Autocast so far, across all conversations: nothing yet."
              : `Made with Autocast so far, across all conversations: ${[...kinds].map(([k, n]) => `${n} ${k}${n === 1 ? "" : "s"}`).join(", ")}.`,
          );
          return lines.join("\n");
        };

        /** The balance, as one line of STATE. Only when they asked about money. */
        const balanceLine = async (): Promise<string> => {
          // Autocast's own meter first: it is what pays for everything made on
          // our generator, and for chat itself (0079). In %, never units.
          const usage = await usageLine(admin, auth.user!.id);
          const { data } = await asUser.rpc("my_connections");
          const door = ((data ?? []) as Array<{ id: string; provider_name: string; auth_kind: string | null; status: string }>)
            .find((c) => c.auth_kind !== "api_key" && c.status === "active");
          if (!door) return usage;
          send({ t: "step", kind: "reading", detail: `Checking your ${door.provider_name} credits` });
          const balance = await balanceFor(admin, door.id);
          return `${usage}\n` + (balance
            ? `Balance on ${door.provider_name}: ${trim(balance.amount)} ${balance.unit}${balance.plan ? ` (${balance.plan} plan)` : ""}.`
            : `Balance: ${door.provider_name} didn't say just now.`);
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
          /** What the card starts on, decided from the request. */
          brief?: VideoBrief | null;
        }) => {
          // What they set once in the generator's settings -- the model, how
          // many, the shape, the quality, a video's length. What they said in
          // this message wins over all of it.
          const pref = job.capability === "image_generation"
            ? body.prefs?.image
            : job.capability === "video_generation"
            ? body.prefs?.video
            : undefined;
          const kept: Record<string, unknown> = {};
          for (const key of ["count", "aspect_ratio", "resolution", "quality", "duration"] as const) {
            const value = pref?.[key];
            if ((typeof value === "string" && value.trim()) || (typeof value === "number" && Number.isFinite(value))) {
              kept[key] = value;
            }
          }
          job = { ...job, settings: { ...kept, ...job.settings } };

          const noun = nounFor(job.capability);
          const aspect = String(job.settings.aspect_ratio ?? "9:16");
          // What comes with it decides who can even attempt it: a picture to
          // start from, a video to work on, a track to follow.
          const brings = await bringsOf(job.references, job.sourceArtifactId);
          const withPicture = brings.image;

          const pool = oneEach(await candidatesFor(admin, auth.user!.id, job.capability));
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
            // Priced for ONE: a count would be multiplied in by some adapters
            // and not others. The card multiplies it, the same way for all.
            quote: {
              prompt: job.prompt,
              options: Object.fromEntries(Object.entries({ aspect_ratio: aspect, ...job.settings }).filter(([key]) => key !== "count")),
            },
            withPicture,
            brings,
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

          // Ask, and it starts. Abel, 1 Nov 2026: "i hate the way it also sends
          // the sheets ... even after u told it use this and generate it, it
          // still asks". The card above replaced a first tap that spent money;
          // now the generator's own settings (the sliders in the bar) hold the
          // model and the rest, a model named in words is used, and the work
          // starts -- the way Grok makes a picture. What it used is said under
          // the result. A photo video keeps its one Make it: its plan is the
          // brief, not a model, and it is the dearest thing made here.
          const startNow = !(job.capability === "video_generation" &&
            (job.brief?.kind === "photo" || (!job.brief && !job.named && !job.sourceArtifactId)));
          if (startNow) {
            let chosen: (typeof choices.options)[number] | undefined;
            if (job.only && job.settled) {
              chosen = affordable.find((o) => o.externalId === choices.options[0]?.externalId);
            } else if (typeof pref?.model === "string" && pref.model && !job.only) {
              chosen = affordable.find((o) => o.externalId === pref.model);
              if (!chosen) {
                // Picked from the full list in settings, so not in the eight.
                const mine = await choicesFor(admin, auth.user!.id, job.capability, { ...intentFor, only: [pref.model] });
                chosen = mine.options.find((o) => o.affordable !== false);
              }
            }
            chosen ??= affordable.find((o) => o.externalId === preselect) ?? affordable[0];

            // Nothing they can afford: the card below says why, with the money.
            if (chosen) {
              const settings: Record<string, unknown> = { ...job.settings };
              const wanted = Number(settings.count);
              delete settings.count;
              // A saved quality or shape goes only where the model has it, in
              // its own spelling -- "Medium" means nothing to a 1K/2K model --
              // and a length snaps to the nearest one it makes.
              const limits = (chosen as { constraints?: { resolutions?: string[]; aspectRatios?: string[]; durations?: number[] } })
                .constraints ?? {};
              const fit = (key: "resolution" | "aspect_ratio", allowed?: string[]) => {
                const value = settings[key];
                if (typeof value !== "string" || !allowed?.length) return;
                const match = allowed.find((option) => option.toLowerCase() === value.toLowerCase());
                if (match) settings[key] = match;
                else delete settings[key];
              };
              fit("resolution", limits.resolutions);
              fit("aspect_ratio", limits.aspectRatios);
              const seconds = settings.duration;
              if (typeof seconds === "number" && limits.durations?.length) {
                settings.duration = limits.durations.reduce((best, d) => Math.abs(d - seconds) < Math.abs(best - seconds) ? d : best);
              }
              const count = job.capability === "image_generation" && Number.isFinite(wanted)
                ? Math.min(10, Math.max(1, Math.round(wanted)))
                : 1;
              const [references, remix] = await Promise.all([
                resolveReferences(job.references),
                job.capability === "image_generation" && !job.sourceArtifactId
                  ? remixIdeas(job.prompt, (model, usage) =>
                    recordUsage(admin, { userId: auth.user!.id, brandId: job.brandId, kind: "remix_ideas", model, usage }))
                  : Promise.resolve([] as string[]),
              ]);
              const input: Record<string, unknown> = {
                capability: job.capability,
                prompt: job.prompt,
                model: chosen.externalId,
                settings,
                quoted_cost: typeof chosen.cost?.amount === "number"
                  ? { unit: chosen.cost.unit, amount: chosen.cost.amount, quoted: true }
                  : null,
                references,
                ...(job.sourceArtifactId ? { source_artifact_id: job.sourceArtifactId } : {}),
                ...(remix.length > 0 ? { remix } : {}),
              };
              const what = job.prompt.split("\n\n")[0].slice(0, 140);
              const lead = job.unmatched ? `I couldn't find "${job.named}", so I'm using ${chosen.label}. ` : "";
              const announce = job.sourceArtifactId
                ? `${lead}Animating it with ${chosen.label}.`
                : `${lead}Making ${count > 1 ? `${count} pictures of ` : ""}${what} with ${chosen.label}.`;
              if (count > 1) return await startBatch(count, input, announce);
              return await startRun("generate", input, null, announce);
            }
          }

          // `total` is every model they have of this kind, so the card can
          // offer the rest: eight rows is a shortlist, not the catalogue.
          const offer = {
            ...choices,
            preselect,
            settings: job.settings,
            total: pool.length,
            withPicture,
            ...(job.brief ? { brief: job.brief } : {}),
          };

          const money = affordable.length === 0 && credits
            ? ` None of these fit your ${credits} right now — topping up on ${pretty(door?.providerSlug) || "your provider"} would unlock them.`
            : credits
            ? ` You have ${credits}.`
            : "";
          // A photo video already has every answer, so there are no provider
          // models to pick from and no credits to talk about: the card has the
          // plan and one button.
          if (job.brief?.kind === "photo") {
            speak("Here's what I'd make. Tap Make it, or change anything first.");
          } else {
            // Said with what is already chosen, so the card reads as one tap,
            // not a form: the model is picked, the count is the one they said.
            const many = Number(job.settings.count) > 1 ? Number(job.settings.count) : 0;
            const what = many ? `${many} pictures of ${job.prompt}` : job.prompt;
            const picked = choices.options.find((o) => o.externalId === preselect)?.label;
            speak(
              job.unmatched ? `I couldn't find "${job.named}" among your models. ` : "",
              job.only && job.settled
                ? `Ready to make ${what} with ${choices.options[0].label}. Tap Generate.`
                : job.only
                ? `More than one model matches "${job.named}". Pick one and tap Generate.`
                : job.intro
                ? `${job.intro} Pick a model and quality, then tap Generate.`
                : picked
                ? `Ready to make ${what} with ${picked}. Tap Generate, or change anything first.`
                : `Let's make ${what}. Pick a model, then tap Generate.`,
              money,
            );
          }
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
              const references = await resolveReferences(action.references ?? []);
              // Settings asked for before the tap -- "2k" -- live on the offer
              // the tap answers, not on the button.
              const offer = await lastOffer();
              const same = offer !== null && offer.request === action.prompt;
              // What they asked for in words, then what they set on the card --
              // the card wins, it is the later and more exact of the two.
              const settings = {
                ...(same ? offer!.settings : {}),
                ...Object.fromEntries(
                  // Anything the card carried, including what the chosen model
                  // asked for by name -- a voice, an engine. The adapter sends
                  // only what the model declares and drops the rest.
                  Object.entries(action.settings ?? {}).filter(([k, v]) =>
                    /^[a-z][a-z0-9_]{0,39}$/.test(k) &&
                    (typeof v === "string" || typeof v === "number")
                  ),
                ),
              };
              // An Animate offer's source travels on the offer, not the button.
              const source = same ? offer!.sourceArtifactId : null;
              // Said once the credits are taken, not before: "Making a lighthouse."
              // followed by "you don't have enough credits" is a sentence that
              // contradicts itself. Only the first paragraph, too -- a line for
              // the voice to speak rides on the end of the prompt.
              const announce = source
                ? "Animating it."
                : `Making ${String(action.prompt ?? "").split("\n\n")[0].slice(0, 140)}.`;
              const quoted = action.quoted && typeof action.quoted.amount === "number"
                ? { unit: String(action.quoted.unit ?? "credits"), amount: action.quoted.amount, quoted: true }
                : null;
              // How many separate pictures. Never sent to a provider: one that
              // reads it makes one picture split into that many.
              const wanted = Number(settings.count);
              delete settings.count;
              const count = capability === "image_generation" && Number.isFinite(wanted)
                ? Math.min(10, Math.max(1, Math.round(wanted)))
                : 1;
              if (count > 1) {
                return await startBatch(count, {
                  capability,
                  prompt: action.prompt,
                  model: action.model ?? null,
                  settings,
                  quoted_cost: quoted,
                  references,
                  ...(source ? { source_artifact_id: source } : {}),
                }, `Making ${count} pictures of ${String(action.prompt ?? "").split("\n\n")[0].slice(0, 120)}.`);
              }
              return await startRun("generate", {
                capability,
                prompt: action.prompt,
                model: action.model ?? null,
                settings,
                quoted_cost: quoted,
                references,
                ...(source ? { source_artifact_id: source } : {}),
              }, null, announce);
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

              // The app on screen, or the oldest when the app did not say.
              const brandQuery = asUser.from("brands").select("id, name, niche, audience");
              const { data: brandRow } = await (brandWanted
                ? brandQuery.eq("id", brandWanted).maybeSingle()
                : brandQuery.order("created_at", { ascending: true }).limit(1).maybeSingle());
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

            if (action.type === "story") {
              // The create card's "Photo video": the same story engine as the
              // typed `/story` command, started with the card's choices.
              const topic = String(action.topic ?? "").replace(/\s+/g, " ").trim().slice(0, 400);
              const slug = String(action.style ?? "").toLowerCase().replace(/[^a-z0-9-]/g, "");
              if (!topic || !slug) {
                speak("Tell me what the video should be about, then tap Create.");
                await remember();
                return finish();
              }
              const { data: styleRow } = await admin.from("content_templates")
                .select("slug, name, visual_style, workflow").eq("slug", slug).maybeSingle();
              const style = styleRow as { slug: string; name: string; visual_style: string | null; workflow: never } | null;
              if (!style) {
                speak(`I don't have a style called “${slug}”. Pick another one on the card.`);
                await remember();
                return finish();
              }
              const support = productionFor(style).support;
              if (support.level === "unsupported") {
                speak(`I can't make “${style.name}” videos from pictures yet: ${support.reason}. Try AI video instead.`);
                await remember();
                return finish();
              }
              const seconds = typeof action.seconds === "number"
                ? Math.min(90, Math.max(15, Math.round(action.seconds)))
                : undefined;
              const voiceId = typeof action.voiceId === "string" && /^[A-Za-z0-9]{10,40}$/.test(action.voiceId)
                ? action.voiceId
                : undefined;
              const captionStyle = typeof action.captionStyle === "string" &&
                  ["bold_pop", "highlight", "minimal", "subtitle", "boxed", "none"].includes(action.captionStyle)
                ? action.captionStyle
                : undefined;
              const look = typeof action.look === "string" ? action.look.replace(/\s+/g, " ").trim().slice(0, 300) : "";
              const direction = typeof action.direction === "string" ? action.direction.replace(/\s+/g, " ").trim().slice(0, 800) : "";

              const { data: brandRow } = await (brandWanted
                ? asUser.from("brands").select("id, name, niche, audience").eq("id", brandWanted).maybeSingle()
                : asUser.from("brands").select("id, name, niche, audience").order("created_at", { ascending: true }).limit(1).maybeSingle());
              const brand = brandRow as { id: string; name: string; niche: string; audience: string } | null;
              const length = seconds ? `${seconds}-second ` : "";
              speak(`Making a ${length}photo video about “${topic}”. I'll show each step, and it keeps going if you close the app.`);
              return await startRun("story", {
                request: {
                  topic,
                  styleSlug: style.slug,
                  ...(seconds ? { durationS: seconds } : {}),
                  ...(action.narration === false ? { narration: false } : {}),
                  ...(look ? { look } : {}),
                  ...(voiceId ? { voiceId } : {}),
                  ...(captionStyle ? { captionStyle } : {}),
                  ...(direction ? { direction } : {}),
                  ...(brand ? { brandContext: `${brand.name}${brand.niche ? ` — ${brand.niche}` : ""}${brand.audience ? `, for ${brand.audience}` : ""}` } : {}),
                },
              }, brand?.id ?? null);
            }
          }

          // `/story <style> [seconds] <topic>`: a typed command, deliberately not
          // a guess from free text, because it starts a long job that spends
          // money. Checked here so a wrong style is answered at once instead of
          // after a run has been created.
          const storyCommand = parseStoryCommand(asked);
          if (storyCommand) {
            const { data: styleRows } = await admin.from("content_templates").select("slug, name, visual_style, workflow").order("sort");
            const styles = (styleRows ?? []) as Array<{ slug: string; name: string; visual_style: string | null; workflow: never }>;
            const usable = styles.filter((s) => productionFor(s).support.level !== "unsupported");

            if (storyCommand.kind === "help" || storyCommand.kind === "error") {
              speak(
                storyCommand.kind === "error" ? `${storyCommand.message}\n\n` : "",
                "Make a finished video from pictures, a voiceover, music and captions:\n\n",
                "`/story <style> [seconds] <topic>`\n\n",
                "For example: `/story scary 60 footsteps in an empty house`\n\n",
                `Styles I can make now: ${usable.map((s) => s.slug).join(", ")}.\n\n`,
                "Add `--no-voice` to skip the narrator. It takes several minutes and keeps going if you close the app.",
              );
              await remember();
              return finish();
            }

            const style = styles.find((s) => s.slug === storyCommand.styleSlug);
            if (!style) {
              speak(`I don't have a style called “${storyCommand.styleSlug}”. Try one of: ${usable.map((s) => s.slug).join(", ")}.`);
              await remember();
              return finish();
            }
            const support = productionFor(style).support;
            if (support.level === "unsupported") {
              speak(`I can't make “${style.name}” videos yet: ${support.reason}. Styles I can make: ${usable.map((s) => s.slug).join(", ")}.`);
              await remember();
              return finish();
            }

            const { data: brandRow } = await (brandWanted
              ? asUser.from("brands").select("id, name, niche, audience").eq("id", brandWanted).maybeSingle()
              : asUser.from("brands").select("id, name, niche, audience").order("created_at", { ascending: true }).limit(1).maybeSingle());
            const brand = brandRow as { id: string; name: string; niche: string; audience: string } | null;
            const length = storyCommand.durationS ? `${storyCommand.durationS}-second ` : "";
            speak(`Starting a ${length}${style.name} story about “${storyCommand.topic}”. I'll tell you each step as it happens, and it keeps going if you close the app.`);
            return await startRun("story", {
              request: {
                topic: storyCommand.topic,
                styleSlug: style.slug,
                ...(storyCommand.durationS ? { durationS: storyCommand.durationS } : {}),
                ...(storyCommand.narration !== undefined ? { narration: storyCommand.narration } : {}),
                ...(brand ? { brandContext: `${brand.name}${brand.niche ? ` — ${brand.niche}` : ""}${brand.audience ? `, for ${brand.audience}` : ""}` } : {}),
              },
            }, brand?.id ?? null);
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
            route(asked, OPENAI_KEY, context, (model, usage) =>
              recordUsage(admin, { userId: auth.user!.id, brandId: brandWanted ?? null, kind: "chat_route", model, usage })),
            brandWanted
              ? asUser.from("brands").select("id, name, niche, audience").eq("id", brandWanted).maybeSingle()
              : asUser.from("brands").select("id, name, niche, audience")
                .order("created_at", { ascending: true }).limit(1).maybeSingle(),
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

          // How the account is doing, answered from the SAME objects the
          // Analytics screen reads: analytics_report, autopilot_report, and
          // what the learning job found and recommends. Chat never makes its
          // own summary of performance -- a second source of numbers is a
          // second set of numbers, and one of them would be wrong.
          if (routed.intent === "insights" && brand) {
            send({ t: "step", kind: "reading", detail: "Reading your analytics" });

            const isoDay = (daysAgo: number) => new Date(Date.now() - daysAgo * 86_400_000).toISOString().slice(0, 10);
            const span = /\b(this|last|past) month\b|\b30 days\b/i.test(asked) ? 30 : /\b(this|last|past) week\b|\b7 days\b/i.test(asked) ? 7 : 28;
            const from = isoDay(span - 1);
            const to = isoDay(0);

            const [reportRead, autopilotRead, insightRead, recRead, libraryRead] = await Promise.all([
              asUser.rpc("analytics_report", { p_brand: brand.id, p_from: from, p_to: to }),
              asUser.rpc("autopilot_report", { p_brand: brand.id, p_from: from, p_to: to }),
              asUser.from("insights")
                .select("statement, evidence, sample_size, confidence, lift, period_start, period_end, platforms, content_types")
                .eq("brand_id", brand.id).eq("status", "active"),
              asUser.from("recommendations")
                .select("title, because, confidence, status")
                .eq("brand_id", brand.id).in("status", ["open", "applied", "planned"]),
              asUser.rpc("library_videos", { p_brand: brand.id }),
            ]);
            // deno-lint-ignore no-explicit-any
            const library = libraryRead.data as Record<string, any> | null;

            // The videos this question is about, in full: any whose title the
            // question quotes, else the newest and the best. "When you ask it
            // for details it doesn't know" was this -- it had one line per
            // video and nothing else.
            // deno-lint-ignore no-explicit-any
            const allVideos = (library?.videos ?? []) as Array<Record<string, any>>;
            const lowered = asked.toLowerCase();
            const named = allVideos.filter((v) => {
              const title = String(v.title ?? "").toLowerCase().replace(/#\S+/g, "").trim();
              return title.length >= 6 && lowered.includes(title.slice(0, Math.min(24, title.length)));
            });
            const best = [...allVideos].sort((a, b) => (b.views ?? 0) - (a.views ?? 0))[0];
            const focus = [...new Map(
              (named.length > 0 ? named : [allVideos[0], best]).filter(Boolean).map((v) => [v.video_id, v]),
            ).values()].slice(0, 3);
            const detailReads = await Promise.all(
              focus.map((v) => asUser.rpc("post_analytics", { p_brand: brand.id, p_video: v.video_id })),
            );
            // deno-lint-ignore no-explicit-any
            const details = detailReads.map((r) => r.data as Record<string, any> | null).filter(Boolean).map((d) => ({
              video: d!.video,
              context: d!.context,
              // The last day of hourly readings is enough to describe a curve.
              readings: ((d!.readings ?? []) as unknown[]).slice(-24),
              post: d!.post,
              comparisons: d!.comparisons,
            }));

            // deno-lint-ignore no-explicit-any
            const report = reportRead.data as Record<string, any> | null;
            // deno-lint-ignore no-explicit-any
            const bucketOf = (b: any) => ({
              start: b.start,
              complete: b.videos > 0 && b.unknown === 0,
              views: b.unknown === 0 ? b.views : null,
              likes: b.unknown === 0 ? b.likes : null,
              comments: b.unknown === 0 ? b.comments : null,
              shares: b.unknown === 0 ? b.shares : null,
            });
            const data = {
              asked_about_days: span,
              range: report?.range ?? null,
              status: report?.status ?? "unknown",
              history_starts: report?.history_starts ?? null,
              availability: report?.availability ?? {},
              totals: report?.totals ?? null,
              // deno-lint-ignore no-explicit-any
              trend: (report?.series ?? []).filter((b: any) => b.period === "current").map(bucketOf),
              videos_with_numbers: report?.videos ?? 0,
              median_views: report?.median_views ?? null,
              top_scope: report?.top_scope ?? null,
              // deno-lint-ignore no-explicit-any
              top: (report?.top ?? []).slice(0, 12).map((v: any) => ({
                title: v.hook || v.title || v.description || "Untitled",
                posted_at: v.posted_at, views: v.views, likes: v.likes, comments: v.comments, shares: v.shares,
                engagement_rate: v.engagement_rate, times_median_views: v.relative,
                format: v.format, theme: v.pillar, duration_s: v.duration_s, made_with_autocast: v.from_autocast,
              })),
              best_time: report?.best_time
                ? {
                  videos: report.best_time.videos, minimum: report.best_time.minimum,
                  best_hours: report.best_time.best_hours, best_day: report.best_time.best_day,
                }
                : null,
              breakdowns: report?.breakdowns ?? [],
              account: library?.account ?? null,
              // deno-lint-ignore no-explicit-any
              latest: ((library?.videos ?? []) as Array<Record<string, any>>).slice(0, 8).map((v) => ({
                title: v.title, posted_at: v.posted_at, views: v.views, likes: v.likes,
                comments: v.comments, shares: v.shares, duration_s: v.duration_s, made_with_autocast: v.from_autocast,
              })),
              learned: insightRead.data ?? [],
              recommendations: recRead.data ?? [],
              autopilot: autopilotRead.data ?? null,
              details,
            };

            const rules = `You are Autocast, a sharp, friendly creator coach, answering a question about how this account's content is performing.
Answer ONLY from DATA. Every number you say must appear in DATA or be simple arithmetic on it.

How to answer:
- Lead with the direct answer in one sentence. Then the two or three numbers that matter. Then one concrete next step.
- Write rates as percentages ("15% engagement", never 0.1506) and big numbers the way people say them ("1.1K views").
- Talk like a person: "your other two videos", not "sample size". No jargon, no hedging paragraphs.
- "Last post" / "latest video" means the newest item in latest, not the top one.
- When a cause can't be proven, still say what stands out against their own other videos (views vs their median, engagement vs the others, how new it is) -- as an observation, clearly not a proven reason.
- details holds the videos this question is about, in depth: video (numbers, length, caption), context (rank among their videos, share of all their views, the other videos' medians for views / engagement / length / hashtags / caption length, the hour it went out, hours live, their best posting block if known), readings (hourly running totals -- use them for "how fast is it growing": views gained per hour, since posting), post (hook, format, theme, when it was Autocast's), comparisons. Use all of it; be specific.
- Watch time, average watch time, retention / where people stopped, traffic sources (For You, search, profile), viewers, new vs returning, gender, age and location are NOT given to apps by TikTok without a TikTok Business connection, which this account does not have yet. When asked for any of them, say exactly that in one sentence, then give what you do know instead.

- totals.current is the last ${span} days, totals.previous the ${span} days before. A total with unknown > 0 is incomplete: say Autocast's history only starts at history_starts, and do not compare it.
- availability says what the platform gives. Reach, saves, watch time, retention, profile visits, link clicks and conversions marked "unavailable" are not shared by TikTok with apps -- say that, never estimate them.
- WHY questions: give a reason only when an item in learned supports it, and say its sample size and confidence. With nothing in learned, say plainly there is not enough data to know why yet and describe what the numbers do show. Never blame the algorithm, trends, timing or luck without a finding.
- WHAT TO POST NEXT: use recommendations and learned. If both are empty, say Autocast needs more public posts before it can recommend reliably, and name the one or two top posts worth building on if top has any.
- Variations: suggest remaking posts whose times_median_views is 2 or more, naming them.
- Best time: only when best_hours or best_day exists, with its confidence (best_hours.slot is the start of a 3-hour block in the brand's timezone; best_day.slot is 1=Monday). Otherwise say it needs at least best_time.minimum videos and has best_time.videos.
- Autopilot: use autopilot. cost_cents null means the provider did not report a cost, not that it was free.
- If they want a plan built from this, say you can: they only need to ask for the plan.
- Short, plain sentences. No headings. No tables unless asked.`;

            // 🔴 Claude Sonnet 5.5 reads the numbers (Netro, 19 Oct 2026: "maybe
            // the open ai is dumb for the analytics"), thinking at medium,
            // streamed as it is written; OpenAI if it cannot.
            let answered;
            try {
              answered = await writeStreaming({
                effort: "medium",
                openaiModel: MODEL,
                messages: [
                  { role: "system", content: rules },
                  { role: "system", content: `DATA:\n${JSON.stringify(data)}` },
                  ...history.slice(-6),
                ],
              }, (piece) => speak(piece));
            } catch (thrown) {
              console.error("insights writer", thrown instanceof Error ? thrown.message : thrown);
              send({ t: "error", message: "The writer could not be reached just now." });
              controller.close();
              return;
            }

            await remember();
            await recordUsage(admin, { userId: auth.user!.id, brandId: brand?.id ?? null, kind: "insight_reply", model: answered.model, usage: answered.usage });
            return finish();
          }

          // A named model means something is being made, even when the words
          // around it ("use nano banana pro2 with 2k resolution") read as chat.
          // An answer to "what should it be of?" continues that request, even
          // though "a cup of tea" on its own reads as chat.
          const continuing = awaiting !== null && (routed.intent === "make" || routed.intent === "chat");

          // "Put that music on the video." Two things already made here, handed
          // to a model that takes both. Said plainly, because it is not a merge:
          // nothing in this app can mux a track onto a file, so the video is
          // MADE AGAIN guided by the sound -- which costs what it costs, and so
          // ends in a card like everything else.
          const soundOnVideo = /\b(music|audio|sound(track)?|song|track|voice ?over)\b/i.test(asked) &&
            /\b(video|clip|reel|footage|it|this|that)\b/i.test(asked) &&
            /\b(add|put|over|onto|on|with|to|combine|merge|mix)\b/i.test(asked);
          if (soundOnVideo && threadId && !pending) {
            const { data } = await asUser.rpc("thread_artifacts", { p_thread: threadId });
            const rows = (data ?? []) as Array<{ id: string; kind: string; body: Record<string, unknown> }>;
            const video = rows.find((row) => row.kind === "video");
            const sound = rows.find((row) => row.kind === "audio");
            if (video && sound) {
              return await produce({
                capability: "video_generation",
                prompt: String(video.body?.prompt ?? "the same scene"),
                settings: routed.settings,
                references: [`artifact:${video.id}`, `artifact:${sound.id}`],
                intro: "Nothing here can just lay a track over a file — a model has to make the video again, following the sound. These can:",
                brandId: brand?.id ?? null,
              });
            }
          }

          /**
           * Every answer the create card would ask for, decided from the
           * request, the pictures sent with it, the account and the series
           * they already set up. Null when it could not be -- the card then
           * asks, as it did before.
           */
          const briefFor = async (subject: string, refs: string[]): Promise<VideoBrief | null> => {
            send({ t: "step", kind: "reading", detail: "Planning the video" });
            const mine = refs.filter((ref) => ref.startsWith(`${auth.user!.id}/uploads/`) && !ref.includes(".."));
            const [styleRead, planRead, pictures] = await Promise.all([
              admin.from("content_templates").select("slug, name, category, visual_style, workflow").order("sort"),
              brand
                ? asUser.from("content_plans")
                  .select("template_slug, duration_s, look, voice_id, caption_style")
                  .eq("brand_id", brand.id)
                  .in("status", ["draft", "proposed", "active", "paused"])
                  .order("created_at", { ascending: false })
                  .limit(1)
                : Promise.resolve({ data: [] }),
              loadPictures(mine.slice(0, 4)),
            ]);
            // Only styles the story engine can make from pictures: the card's
            // Make it must never lead to "I can't make that yet".
            const styles = ((styleRead.data ?? []) as Array<{ slug: string; name: string; category: string | null; visual_style: string | null; workflow: never }>)
              .filter((s) => productionFor(s).support.level !== "unsupported")
              .map((s) => ({ slug: s.slug, name: s.name, category: s.category }));
            const plan = ((planRead.data ?? []) as Array<{
              template_slug: string | null;
              duration_s: number | null;
              look: string | null;
              voice_id: string | null;
              caption_style: string | null;
            }>)[0];
            return await makeBrief({
              apiKey: OPENAI_KEY!,
              request: subject,
              message: asked,
              pictures,
              context: {
                styles,
                brand,
                facts: known,
                series: plan
                  ? {
                    style: plan.template_slug,
                    seconds: plan.duration_s,
                    look: plan.look,
                    voiceId: plan.voice_id,
                    captions: plan.caption_style,
                  }
                  : null,
                conversation: context,
              },
              onUsage: (model, usage) =>
                recordUsage(admin, { userId: auth.user!.id, brandId: brand?.id ?? null, kind: "video_brief", model, usage }),
            });
          };

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
            // A picture they sent a message or two ago is still what "make 4
            // more" and "try it with GPT Image 2" mean -- a set made straight
            // away leaves no card to carry it, and twice a retry came back
            // without the outfit it was meant to follow.
            const references = attachments.length > 0
              ? attachments
              : (pending?.references ?? awaiting?.references ?? theirs);

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
                  oneEach(await candidatesFor(admin, auth.user!.id, cap)).map((c) => ({ ...c, capability: cap as Capability }))
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

            // A plain request for a video, with no model named and nothing to
            // animate: decide everything the card would ask, from what they
            // said, what they sent and what their series already is.
            const planned = capability === "video_generation" && !namedModel && !sourceArtifactId && !animating &&
                !!OPENAI_KEY
              ? await briefFor(prompt, references)
              : null;
            // Pictures sent as examples to follow are read into the brief, not
            // handed to a video model as a first frame -- that would make the
            // photo video impossible, and they did not ask for it.
            const forModel = planned?.kind === "photo" && planned.uses === "inspiration"
              ? references.filter((ref) => ref.startsWith("artifact:"))
              : references;

            return await produce({
              capability,
              prompt,
              settings,
              references: forModel,
              // Answering an offer that was for animating something, or saying
              // "animate this", animates that thing.
              sourceArtifactId,
              only,
              settled,
              unmatched,
              named: namedModel,
              brandId: brand?.id ?? null,
              brief: planned,
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
Autocast brings the models: nothing needs connecting to make a picture or a video.
Their plan is a month of usage shown as a %, like Claude's or ChatGPT's. Chat
replies, plans and captions take a tiny share; a picture well under 1%; a
five-second video on Pro about 1 to 16%, depending on the model. The share is shown before
anything is made, and it fills up again each month from the day they subscribed.
There is nothing to top up: when the month is used up they wait for it to fill,
or move to a bigger plan (Max is 3x Pro, Ultra about 8x). Free makes nothing; it is a
few chat messages. Never talk about "credits" or a balance for Autocast's own
generator -- say % of their month.
</this_app>

<state>
The STATE block in the next message is the live truth about their account: what
is connected, what you recently made or tried to make in this conversation and
how it ended, prices you have seen, and how much of their month is left when it
was checked. Use it. If they ask whether they have enough, answer from it with
the actual numbers, and suggest the cheaper option that would work.

The ACCOUNT block is their connected TikTok: handle, followers, likes, their
latest public videos with numbers, and everything Autocast has made for them
across all conversations. You CAN see these. Never say you have no access to
their TikTok, their posts or what you made together -- answer from ACCOUNT.
Only what is not in it is unknown (private videos, drafts, when the account was
created); say that plainly and say what you can see instead. For deeper
analysis, the Analytics tab has the full picture.
</state>

<honesty>
Everything you may treat as true about their brand is in FACTS. Nothing else is
known about it, and you never fill the gap:
- Never announce product changes ("this week we added...", "now with...").
- Never invent a person or their words: no testimonials, reviews, "a customer
  said", "people keep asking".
- Never invent a number about the account: users, sales, ratings, dates, streaks.
If what they asked for needs one of these, say which fact you need.
Never say you made something that STATE does not list, and never say a picture
matches what they asked unless you can see it and it does. When they say what you
made is wrong, believe them first: look at the picture if one is attached, say
plainly what is off, and offer to redo it -- never "I already did that".
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
<state>Autocast usage this month (Pro plan): 96% used, 4% left, fills up again
on 3 Dec. Last video: Seedance 2.0 Fast, needed about 24%, refused. Prices seen:
Kling 2.5 Turbo Pro about 4%, MiniMax H3 Max Turbo about 3%.</state>
<user>so do I have to pay more or what?</user>
<good>Not necessarily. That Seedance clip needed about 24% of your month and you
have 4% left, so it couldn't run -- but Kling 2.5 Turbo is about 4% and would fit.
Want me to make it with that instead? Your month fills up again on 3 Dec, and Max
gives you three times as much if you want the bigger models before then.</good>
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

          // What the owner wrote under Chat settings (0056): how to talk to
          // them. Their words, verbatim, after the rules -- it shapes tone
          // and length; it cannot turn the honesty rules off.
          let ownerBlock = "";
          if (brand) {
            const { data: settingsRow } = await asUser
              .from("brand_settings")
              .select("chat_instructions")
              .eq("brand_id", brand.id)
              .maybeSingle();
            const instructions = (settingsRow?.chat_instructions ?? "").trim();
            if (instructions) {
              ownerBlock = `OWNER'S INSTRUCTIONS (how they want you to talk to them; follow these unless they conflict with the honesty rules):\n${instructions}`;
            }
          }

          const stateBlock = [
            routed.aboutCredits ? `${baseState}\n${await balanceLine()}` : baseState,
            await accountLines(brand?.id ?? null),
          ].join("\n\n");

          // Attached pictures go to the model as image data on the last turn,
          // so "write a caption for this" is about this picture.
          const pictures = await loadPictures(attachments);
          if (pictures.length > 0) {
            send({ t: "step", kind: "reading", detail: pictures.length === 1 ? "Looking at your picture" : `Looking at your ${pictures.length} pictures` });
          }

          // The pictures from earlier in this conversation -- what they sent and
          // what was made -- so "go check the one I sent" and "you know what I
          // asked" are answered by looking. Abel, 1 Nov 2026: "after it sent
          // you a photo, it doesn't know what the photo is ... when you ask it,
          // it doesn't know what you sent." The history the app sends is words
          // only; the pictures were never in it. Asked about four outfits that
          // came back as flowers, the reply said "I already generated that".
          //
          // The last four, newest one at full detail and the rest at low (85
          // tokens each), so a conversation full of pictures stays cheap.
          const earlier: Array<{ type: "image_url"; image_url: { url: string; detail: "low" | "auto" } }> = [];
          const earlierLines: string[] = [];
          if (threadId) {
            const { data: rows } = await asUser
              .from("messages")
              .select("role, render_hint")
              .eq("thread_id", threadId)
              .order("seq", { ascending: false })
              .limit(24);
            const found: Array<{ path?: string; artifactId?: string; who: "sent" | "made" }> = [];
            for (const row of (rows ?? []) as Array<{ role: string; render_hint: Record<string, unknown> | null }>) {
              const hint = row.render_hint;
              if (row.role === "user" && hint?.kind === "attachments" && Array.isArray(hint.paths)) {
                // This turn's own pictures are already attached above.
                for (const path of hint.paths.map(String)) if (!attachments.includes(path)) found.push({ path, who: "sent" });
              } else if (row.role === "assistant" && hint?.kind === "artifact" && typeof hint.artifact_id === "string") {
                found.push({ artifactId: hint.artifact_id, who: "made" });
              }
              if (found.length >= 6) break;
            }
            const ids = found.flatMap((f) => (f.artifactId ? [f.artifactId] : []));
            const { data: madeRows } = ids.length > 0
              ? await asUser.from("artifacts").select("id, kind, storage_path, body").in("id", ids)
              : { data: [] };
            const made = new Map(
              ((madeRows ?? []) as Array<{ id: string; kind: string; storage_path: string | null; body: Record<string, unknown> | null }>)
                .filter((row) => row.kind === "image" && row.storage_path)
                .map((row) => [row.id, row]),
            );
            const usable = found
              .filter((f) => f.path || (f.artifactId && made.has(f.artifactId)))
              .slice(0, 4)
              .reverse();
            for (const [index, item] of usable.entries()) {
              const row = item.artifactId ? made.get(item.artifactId) : undefined;
              const [loaded] = await loadPictures([item.path ?? row!.storage_path!]);
              if (!loaded) continue;
              earlier.push({
                type: "image_url",
                image_url: { url: loaded.image_url.url, detail: index === usable.length - 1 ? "auto" : "low" },
              });
              const about = typeof row?.body?.prompt === "string" ? ` of "${String(row.body.prompt).slice(0, 120)}"` : "";
              earlierLines.push(`${earlier.length}. ${item.who === "sent" ? "a picture they sent you" : `a picture you made${about}`}`);
            }
          }

          const turns = history.map((turn, index) => {
            if (index !== history.length - 1 || pictures.length + earlier.length === 0) return turn;
            const note = earlier.length > 0
              ? `\n\n(For you only: after ${pictures.length > 0 ? "the pictures they just sent" : "their message"} come pictures from earlier in this conversation, oldest first:\n${earlierLines.join("\n")}\nUse them when they refer back to a picture. Judge what you made honestly against what they asked for.)`
              : "";
            return { role: turn.role, content: [{ type: "text", text: `${turn.content}${note}` }, ...pictures, ...earlier] };
          });

          const upstream = await fetch("https://api.openai.com/v1/chat/completions", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${OPENAI_KEY}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: MODEL,
              stream: true,
              // The last chunk then carries the real token counts.
              stream_options: { include_usage: true },
              messages: [
                { role: "system", content: system },
                { role: "system", content: [brief, factBlock, stateBlock, avoid, ownerBlock].filter(Boolean).join("\n\n") },
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
          let usage: { prompt_tokens?: number; completion_tokens?: number } | null = null;

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
                if (parsed?.usage) usage = parsed.usage;
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
          await recordUsage(admin, { userId: auth.user.id, brandId: brand?.id ?? null, kind: "chat_reply", model: MODEL, usage });
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
