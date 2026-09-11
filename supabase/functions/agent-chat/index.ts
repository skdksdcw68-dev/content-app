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
import { missingForPlan, MODELS, route } from "../_shared/route.ts";
import { choicesFor, matchModels, settlesOn } from "../_shared/connectors/choose.ts";
import { candidatesFor } from "../_shared/connectors/route.ts";
import { rediscover } from "../_shared/connectors/discovery.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
/** Only ever used to write the assistant's own turn. The client's policy in
 *  0002 allows it to insert `role = 'user'` and nothing else, on purpose: an
 *  assistant message the app could write is one it could forge. */
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");

/** Conversation runs on the middle tier. The router above it is cheaper and
 *  the strategy work below it is dearer -- see `MODELS` in _shared/route.ts for
 *  what each tier is for and why one model everywhere is how you bankrupt a
 *  product that answers "hi" at strategy prices. */
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
    capability: "image_generation" | "video_generation";
    prompt: string;
    /** The `externalId` of a picked model. Absent means Auto. */
    model?: string;
    references?: string[];
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

    if (history.length === 0) throw new PublicError("Say something first.");
    if (history[history.length - 1].role !== "user") {
      throw new PublicError("The last message has to be yours.");
    }

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const asked = history[history.length - 1].content;

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
        .rpc("open_thread", { p_brand: body.brandId ?? null, p_title: asked });
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
          };
        };

        /** Artefacts in this conversation, newest first -- what "it" means. */
        const latestExportable = async (): Promise<{ id: string; kind: string; title: string } | null> => {
          if (!threadId) return null;
          const { data } = await asUser.rpc("thread_artifacts", { p_thread: threadId });
          const rows = (data ?? []) as Array<{ id: string; kind: string; title: string }>;
          return rows.find((row) => ["research", "plan", "campaign"].includes(row.kind)) ?? null;
        };

        try {
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
              const capability = action.capability === "image_generation" ? "image_generation" : "video_generation";
              const references = (action.references ?? [])
                .filter((path) => path.startsWith(`${auth.user!.id}/uploads/`) && !path.includes(".."))
                .map((path) => ({ path, kind: "image" }));
              // Settings asked for before the tap -- "2k" -- live on the offer
              // the tap answers, not on the button.
              const offer = await lastOffer();
              const settings = offer && offer.request === action.prompt ? offer.settings : {};
              speak(capability === "image_generation" ? "Making the image." : "Making the video.");
              return await startRun("generate", {
                capability,
                prompt: action.prompt,
                model: action.model ?? null,
                settings,
                references,
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
                `Bring this image to life with subtle, natural motion. ${String(source.body?.prompt ?? "")}`.trim();
              speak("Animating it.");
              return await startRun("generate", {
                capability: "video_generation",
                prompt,
                source_artifact_id: source.id,
                // Same provider first, so the image can be handed back by its
                // own handle rather than re-uploaded.
                model: null,
              }, null);
            }
          }

          // Read under RLS, as the user. Each step is announced only after the
          // read it describes has returned, so the trail can never claim work
          // that did not happen.
          const { data: brand } = await asUser
            .from("brands")
            .select("id, name, niche, audience")
            .limit(1)
            .maybeSingle();

          send({
            t: "step",
            kind: "reading",
            detail: brand ? `Read what you've told me about ${brand.name}` : "Looked for your brand",
          });

          const { data: facts } = brand
            ? await asUser
              .from("brand_memory")
              .select("fact")
              .eq("brand_id", brand.id)
              .limit(40)
            : { data: [] };

          const known = (facts ?? [])
            .map((row: { fact: string }) => row.fact)
            .filter(Boolean);

          if (known.length > 0) {
            send({ t: "step", kind: "reading", detail: `Checked ${known.length} things I know are true` });
          }

          const { data: recent } = await asUser
            .from("posts")
            .select("hook")
            .order("created_at", { ascending: false })
            .limit(15);

          const previous = (recent ?? [])
            .map((row: { hook: string }) => row.hook)
            .filter(Boolean);

          if (previous.length > 0) {
            send({ t: "step", kind: "reading", detail: `Looked at your last ${previous.length} openings` });
          }

          // What are they actually asking for -- read WITH the conversation.
          // One line alone is how "Try again please" became a request to plan
          // a week, and "Use nano banana pro2" a request for a video.
          const pending = await lastOffer();
          const context = [
            ...history.slice(0, -1).slice(-6).map((turn) =>
              `${turn.role === "user" ? "Person" : "Autocast"}: ${turn.content.replace(/\s+/g, " ").slice(0, 300)}`
            ),
            ...(pending
              ? [`(Autocast then offered ${pending.capability === "image_generation" ? "image" : "video"} models for: "${pending.request}")`]
              : []),
          ].join("\n");
          const routed = await route(asked, OPENAI_KEY, context);

          send({ t: "step", kind: "reading", detail: routed.reading });

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
            if (!source) {
              speak("There's nothing in this conversation to export yet. Ask me to research something or plan a month, and I can turn it into a file.");
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
          if (routed.intent === "make" || routed.model) {
            // WHAT to make: the subject the router pulled out, or what the
            // last offer was for. Never the raw sentence -- the first real
            // image went to Higgsfield with the prompt "I want a photo or
            // image not a video", and came back as exactly that much sense.
            const prompt = routed.subject?.trim() || pending?.request || asked;
            const settings = { ...(pending?.settings ?? {}), ...routed.settings };
            const references = attachments.length > 0 ? attachments : (pending?.references ?? []);

            // Which kind: a model they named settles it, then what they said,
            // then what was already on offer, then video.
            let capability: "image_generation" | "video_generation" = routed.media === "image"
              ? "image_generation"
              : routed.media === "video"
              ? "video_generation"
              : pending?.capability === "image_generation" || pending?.capability === "video_generation"
              ? pending.capability
              : "video_generation";

            // A name is looked up across EVERYTHING they have, not the eight
            // on screen -- "nano banana pro" was not in the first eight image
            // models, and was answered with a list of video models instead.
            let only: string[] | undefined;
            let unmatched = false;
            let settled = false;
            if (routed.model) {
              const pools = await Promise.all(
                (["image_generation", "video_generation"] as const).map(async (cap) =>
                  (await candidatesFor(admin, auth.user!.id, cap)).map((c) => ({ ...c, capability: cap }))
                ),
              );
              const matches = matchModels(pools.flat(), routed.model);
              if (matches.length > 0) {
                // A name can span kinds -- Higgsfield has three Kling video
                // models and a Kling image one. The kind comes from what they
                // said, then from what they were just choosing between, then
                // from where most of the matches are.
                const kinds = new Set(matches.map((m) => m.capability));
                const said = routed.media === "image"
                  ? "image_generation"
                  : routed.media === "video"
                  ? "video_generation"
                  : null;
                const offered = pending && kinds.has(pending.capability as typeof capability)
                  ? pending.capability as typeof capability
                  : null;
                capability = said && kinds.has(said)
                  ? said
                  : offered ?? [...kinds].sort((a, b) =>
                    matches.filter((m) => m.capability === b).length - matches.filter((m) => m.capability === a).length
                  )[0];

                const same = matches.filter((m) => m.capability === capability).slice(0, 4);
                const exact = settlesOn(same, routed.model);
                // Started without asking only when nothing about it is a
                // guess: one model, and the kind either certain or said.
                settled = exact !== null && (kinds.size === 1 || said !== null || offered !== null);
                only = settled && exact ? [exact.externalId] : same.map((m) => m.externalId);
              } else {
                unmatched = true;
              }
            }
            const noun = capability === "image_generation" ? "image" : "video";
            const aspect = settings.aspect_ratio ?? "9:16";

            const intentFor = {
              aspectRatio: aspect,
              seconds: settings.duration ?? (noun === "video" ? 5 : undefined),
              // Asked of the provider with this very prompt and these settings,
              // so the price on each row is what this job costs.
              quote: { prompt, options: { aspect_ratio: aspect, ...settings } },
              withPicture: references.length > 0,
              only,
            };
            let choices = await choicesFor(admin, auth.user.id, capability, intentFor);

            // Nothing found, but something is signed in: ask it again before
            // saying no. The contract promised discovery would re-run "whenever
            // a capability lookup finds nothing", and the first real sign-in
            // is why -- it connected, lost its model list to a failed write,
            // and chat then told Abel he had nothing that could make an image.
            if (choices.options.length === 0) {
              const { data: signedIn } = await asUser
                .from("connections")
                .select("id, auth_kind")
                .eq("status", "active")
                .is("revoked_at", null);
              const doors = ((signedIn ?? []) as Array<{ id: string; auth_kind: string | null }>)
                .filter((row) => row.auth_kind !== "api_key");

              if (doors.length > 0) {
                send({ t: "step", kind: "reading", detail: "Asking your provider what it can make" });
                for (const door of doors) {
                  try {
                    await rediscover(admin, door.id);
                  } catch (thrown) {
                    console.error("rediscover", thrown instanceof Error ? thrown.message : thrown);
                  }
                }
                choices = await choicesFor(admin, auth.user.id, capability, intentFor);
              }
            }

            if (choices.options.length === 0) {
              speak(
                `Nothing you have connected can make ${noun === "image" ? "images" : "video"} yet. `,
                "Connect a generator from the plus menu and I can start straight away.",
              );
              await remember();
              return finish();
            }

            send({
              t: "step",
              kind: "reading",
              detail: only
                ? `Found ${choices.options.length === 1 ? choices.options[0].label : `${choices.options.length} models called that`}`
                : `Found ${choices.options.length} ${noun} model${choices.options.length === 1 ? "" : "s"} you can use`,
            });

            const priced = (cost: { amount: number | null; unit: string }) =>
              cost.amount === null ? "" : ` (${Number(cost.amount.toFixed(2))} ${cost.unit})`;

            // Exactly the one they named -- every word they typed, in one
            // model's name -- so naming it was the choice and it starts, with
            // its price said. A looser match is asked about instead: a tap is
            // cheaper than credits spent on a guess.
            if (only && settled && choices.options.length === 1) {
              const chosen = choices.options[0];
              speak(
                `Using ${chosen.label}${priced(chosen.cost)}`,
                settings.resolution ? ` at ${settings.resolution}` : "",
                ` for ${prompt}.`,
              );
              send({ t: "chose", choice: chosen });
              return await startRun("generate", {
                capability,
                prompt,
                model: chosen.externalId,
                settings,
                quoted_cost: chosen.cost.amount !== null ? chosen.cost : null,
                references: references.map((path) => ({ path, kind: "image" })),
              }, brand?.id ?? null);
            }

            if (choices.worthAsking) {
              speak(
                unmatched ? `I couldn't find "${routed.model}" among your models. ` : "",
                only
                  ? `More than one model matches "${routed.model}" — which one?`
                  : `I can make ${prompt}. These ${choices.options.length} can do it — pick one, or let me choose.`,
              );
              // The request travels with the offer -- the SUBJECT, not the
              // sentence -- so a tap on a model starts exactly this job, and a
              // typed "use Kling" afterwards still knows what to make.
              send({ t: "models", capability, choices, request: prompt, references });
              await remember({ kind: "models", choices, request: prompt, references, settings });
              return finish();
            }

            // Not worth asking, so it is not asked -- and now it actually
            // starts, rather than saying "Starting now" and doing nothing. The
            // choice and its price are still reported: somebody should always
            // be able to see what was used and what it cost.
            const auto = choices.auto;
            speak(
              `I'll use ${auto?.label ?? "the one model you have"}`,
              auto ? `${priced(auto.cost)}. ` : ". ",
              auto?.reason ? `${auto.reason} ` : "",
            );
            send({ t: "chose", choice: auto });
            return await startRun("generate", {
              capability,
              prompt,
              model: auto?.externalId ?? null,
              settings,
              quoted_cost: auto?.cost.amount !== null ? auto?.cost : null,
              references: references.map((path) => ({ path, kind: "image" })),
            }, brand?.id ?? null);
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

          send({ t: "step", kind: "writing", detail: "Writing" });

          // Tagged sections rather than a flat list of sentences, and a banned
          // list of actual phrasings rather than a principle.
          //
          // Both are borrowed technique. A small model follows "never write
          // this exact shape of sentence" and reasons badly about "only assert
          // what you know" -- which is how the planner came to announce
          // features Remi does not have. The good/bad pairs are there for the
          // same reason: showing the refusal is worth more than describing it,
          // because the failure is not that the model wants to lie, it is that
          // it does not know what a refusal is supposed to sound like.
          const system = `<autocast>
You are Autocast, the content agent for one social account. You plan, write and
schedule short-form video for the person you are talking to. You are talking to
the owner of the account, not to their audience.

<facts>
Everything you may treat as true about this account is in the FACTS block of the
next message. Nothing else is known. An empty FACTS block means you know only
the account line, and you should say so rather than filling the gap.
</facts>

<forbidden_claims>
You NEVER state as fact anything not in FACTS. In particular:

Never announce work that was done:
- "This week I added..." / "We shipped..." / "I fixed..." / "Now with..."
- "...just launched" / "...has been improved" / "...is now simpler"
- Any sentence whose subject is a change to the product.

Never invent a person or their words:
- "One user told me..." / "A customer said..." / "People keep asking..."
- Any quote, testimonial, review or DM.

Never invent a measurement:
- A number of users, downloads, reviews, ratings, or revenue.
- A price, a date, a percentage, a milestone, a streak.
- "thousands of" / "hundreds of" / "most people" as a claim about this account.

If what you are asked for needs one of these, name the fact you are missing and
ask for it. That is the correct answer, not a fallback.
</forbidden_claims>

<voice>
Talk like somebody who knows the account. Short sentences. No hype, no
exclamation marks, no "unlock", "game-changer", "supercharge", and never the
word easy. Under 120 words unless more is asked for. A list only when the answer
really is a list.
</voice>

<what_you_cannot_do>
You cannot publish, approve, or attach media, and you must never imply you have.
Everything that reaches TikTok goes through the approval sheet, which is a
person tapping a button. Say "I can draft that" and never "I posted that".
</what_you_cannot_do>

<examples>
These examples are about a DIFFERENT account, called Kettle, which sells loose
leaf tea. Nothing in them is a fact about the account you are working on. They
show you the shape of a good answer and nothing else — never repeat their
wording, their claims, or their product details in a real reply.

<example>
<facts>none recorded</facts>
<user>Write me a post about what's new in Kettle this week.</user>
<good_response>I don't have anything recorded about what changed this week, and I'm not going to invent a feature — that's the one mistake that's expensive to post. Tell me what actually shipped and I'll write it. Or if nothing shipped, I can write about something Kettle already does.</good_response>
<bad_response>Here's one: "This week I added a subscription pause button — a small change that makes a big difference."</bad_response>
</example>

<example>
<facts>Kettle sells loose leaf tea. Every order is packed the morning it ships.</facts>
<user>Give me a hook about people loving it.</user>
<good_response>I don't have anything from customers I can quote, so I'd rather use something I know is true: "Packed the morning it ships." That's a real difference and it argues for itself.</good_response>
<bad_response>"One customer told me Kettle is the best tea they've ever had."</bad_response>
</example>

<example>
<facts>Kettle sells loose leaf tea.</facts>
<user>how's it going</user>
<good_response>Fine. What do you want to work on?</good_response>
<bad_response>Going great! Kettle's been picking up steam lately and I've got some exciting ideas for growing your audience!</bad_response>
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
            send({ t: "step", kind: "reading", detail: `Looked at ${pictures.length === 1 ? "your picture" : `${pictures.length} pictures`}` });
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
                { role: "system", content: [brief, factBlock, avoid].filter(Boolean).join("\n\n") },
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
