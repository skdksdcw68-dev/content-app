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
import { choicesFor } from "../_shared/connectors/choose.ts";

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

interface Body {
  messages?: Turn[];
  /** The conversation this belongs to. Omitted on the first turn, and the id of
   *  the thread opened for it comes back on the stream. */
  threadId?: string;
  brandId?: string;
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
          if (routed.intent === "make") {
            const choices = await choicesFor(admin, auth.user.id, "video_generation", {
              aspectRatio: "9:16",
              seconds: 5,
            });

            if (choices.options.length === 0) {
              for (
                const chunk of [
                  "Nothing you have connected can make video yet. ",
                  "Connect a generator from the plus menu and I can start straight away.",
                ]
              ) {
                said += chunk;
                send({ t: "delta", v: chunk });
              }
              await remember();
              send({ t: "done" });
              controller.close();
              return;
            }

            send({
              t: "step",
              kind: "reading",
              detail: `Found ${choices.options.length} video model${
                choices.options.length === 1 ? "" : "s"
              } you can use`,
            });

            if (choices.worthAsking) {
              for (
                const chunk of [
                  "I can make that. ",
                  `You have ${choices.options.length} video models available — `,
                  "pick one, or let me choose.",
                ]
              ) {
                said += chunk;
                send({ t: "delta", v: chunk });
              }

              send({ t: "models", capability: "video_generation", choices });
              await remember({ kind: "models", choices });
              send({ t: "done" });
              controller.close();
              return;
            }

            // Not worth asking, so it is not asked. The choice is still
            // reported -- somebody should always be able to see what was used
            // and what it cost, even when they were not consulted.
            const auto = choices.auto;
            for (
              const chunk of [
                `I'll use ${auto?.label ?? "the one model you have"}. `,
                auto?.reason ? `${auto.reason} ` : "",
                "Starting now.",
              ]
            ) {
              if (!chunk) continue;
              said += chunk;
              send({ t: "delta", v: chunk });
            }
            send({ t: "chose", choice: auto });
            await remember({ kind: "chose", choice: auto });
            send({ t: "done" });
            controller.close();
            return;
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
                // month gets built.
                send({ t: "questions", questions });
                // The questions go into the transcript with the turn, so
                // reopening the thread shows what was asked rather than a
                // sentence promising questions that are no longer there.
                await remember({ kind: "questions", questions });
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
