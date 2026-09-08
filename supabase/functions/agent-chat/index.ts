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

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
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

interface Body {
  messages?: Turn[];
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

    const stream = new ReadableStream({
      async start(controller) {
        const send = (event: Record<string, unknown>) =>
          controller.enqueue(new TextEncoder().encode(sse(event)));

        try {
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

          // What are they actually asking for? One cheap call before any
          // decision about what to spend. See _shared/route.ts.
          const asked = history[history.length - 1].content;
          const routed = await route(asked, OPENAI_KEY);

          send({ t: "step", kind: "reading", detail: routed.reading });

          // The gate. A month of content is the single most expensive thing
          // this product does, and the worst version of it is a month built
          // against the wrong goal -- so it does not start until the goal is
          // known and a person has agreed to it.
          //
          // Only what is genuinely missing is asked. `brand_knowledge` reports
          // what the database already holds, and a question somebody already
          // answered during setup is the fastest way to feel stupid.
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
                  send({ t: "delta", v: chunk });
                }

                // Rendered as taps by the app. Sent as data rather than as a
                // numbered list in the prose, because the answers come back as
                // values and parsing them out of a sentence is how the wrong
                // month gets built.
                send({ t: "questions", questions });
                send({ t: "done" });
                controller.close();
                return;
              }
            }
          }

          send({ t: "step", kind: "writing", detail: "Writing" });

          const system = [
            "You are Autocast, the content agent for one social account. You plan, write and schedule short-form video for the person you are talking to.",
            "",
            "FACTS: everything you may treat as true about this account is listed under FACTS below. Nothing else is known.",
            "NEVER write that anything was changed, added, removed, fixed, improved, tweaked, refined, updated, simplified, launched or shipped unless a FACT says so.",
            "NEVER invent a number, a price, a date, a rating, a milestone, or a person. NEVER write a customer quote, a testimonial, or \"one user told me\".",
            "If you are asked for something the FACTS cannot support, say plainly which fact you are missing and ask for it. That is a better answer than a confident invention.",
            "",
            "Talk like a person who knows the account. Short sentences. No hype, no exclamation marks, no \"unlock\" or \"game-changer\", and never the word easy.",
            "Keep replies under 120 words unless asked for more. Use a short list only when the answer really is a list.",
            "",
            "You cannot publish, approve, or attach media, and you must never imply you have. Everything that reaches TikTok goes through the approval sheet.",
            "If the person wants a month of content, say so and tell them to use Plan 30 days -- that runs a different, longer job.",
          ].join("\n");

          const brief = brand
            ? `Account: ${brand.name}. Subject: ${brand.niche || "not stated"}. Audience: ${brand.audience || "not stated"}.`
            : "The account has not described itself yet.";

          const factBlock = known.length > 0
            ? `FACTS:\n${known.map((fact) => `- ${fact}`).join("\n")}`
            : "FACTS: none recorded yet. You know only the account line above. Say so when it matters, and suggest adding facts under Brand.";

          const avoid = previous.length > 0
            ? `Openings already used, do not repeat them:\n${previous.map((hook) => `- ${hook}`).join("\n")}`
            : "";

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
                ...history,
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
          send({ t: "done" });
          controller.close();
        } catch (thrown) {
          console.error("agent-chat", thrown);
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
