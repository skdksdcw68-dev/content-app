/**
 * The writer: every AI call that is about a post, research or the numbers.
 *
 * Netro, 19 Oct 2026: "If it's about a post, post research, analytics, or
 * things like this, it must be with a Claude API key." Analytics answers,
 * campaign strategy, research, plan and Autopilot writing, captions, video
 * understanding, plan import and Home's ideas all come through here and run
 * on Claude Sonnet 5.5. Chat replies and the message router stay on OpenAI
 * (`_shared/route.ts`).
 *
 * Callers keep the shape they already had -- OpenAI-style messages in, an
 * OpenAI-style completion out (`choices[0].message.content`, `usage`,
 * `model`) -- so each one changed by a line, and `recordUsage` prices it from
 * the model it names.
 *
 * Falls back to OpenAI on its own: when there is no Anthropic key, or Claude
 * fails or declines. A post still gets written; the usage row says which model
 * wrote it.
 */

import Anthropic from "npm:@anthropic-ai/sdk@0.131.0";

/** The model for writing about posts. One place to change it. */
export const CLAUDE_WRITER = Deno.env.get("CLAUDE_MODEL") ?? "claude-sonnet-5-5";

const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY") ?? "";

let client: Anthropic | null = null;
function claude(): Anthropic | null {
  if (!ANTHROPIC_KEY) return null;
  client ??= new Anthropic({ apiKey: ANTHROPIC_KEY });
  return client;
}

type Part =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string; detail?: string } };

/** A message the way the callers already write them. */
export interface WriterMessage {
  role: "system" | "user" | "assistant";
  content: string | Part[];
}

export interface WriterRequest {
  messages: WriterMessage[];
  /** Asks for one JSON object back, and returns only that. */
  json?: boolean;
  /** How hard Claude thinks. `low` for writing posts and captions; `medium`
   *  for reading numbers, strategy and research. */
  effort?: "low" | "medium" | "high";
  /** The OpenAI model this call used before, for the fallback. */
  openaiModel: string;
  /** Who writes it. Claude unless said otherwise. Netro, 19 Oct 2026:
   *  captions and Home's ideas are ChatGPT's -- "its smarter for this" -- so
   *  those two say `openai` and never touch Claude. */
  prefer?: "claude" | "openai";
  maxTokens?: number;
}

/** The OpenAI-shaped answer every caller already reads. */
export interface Completion {
  model: string;
  usage: { prompt_tokens: number; completion_tokens: number; total_tokens: number };
  choices: Array<{ message: { content: string } }>;
}

const JSON_RULE = "Reply with one JSON object and nothing else: no prose before or after it, no code fences.";

/** The first whole JSON object in a reply, for a model that wrapped it. */
function jsonOnly(text: string): string {
  const trimmed = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  if (trimmed.startsWith("{")) return trimmed;
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  return start >= 0 && end > start ? trimmed.slice(start, end + 1) : trimmed;
}

/** OpenAI-style messages as Claude's: the system turns become the system
 *  prompt, and a data-URL image becomes a base64 image block. */
function toClaude(request: WriterRequest): { system: string; messages: Anthropic.MessageParam[] } {
  const system = request.messages
    .filter((m) => m.role === "system")
    .map((m) => (typeof m.content === "string" ? m.content : m.content.map((p) => p.type === "text" ? p.text : "").join("\n")))
    .concat(request.json ? [JSON_RULE] : [])
    .join("\n\n");

  const messages: Anthropic.MessageParam[] = request.messages
    .filter((m) => m.role !== "system")
    .map((m) => {
      if (typeof m.content === "string") return { role: m.role as "user" | "assistant", content: m.content };
      const blocks: Anthropic.ContentBlockParam[] = m.content.map((part) => {
        if (part.type === "text") return { type: "text", text: part.text };
        const data = /^data:(image\/[a-z]+);base64,(.+)$/i.exec(part.image_url.url);
        return data
          ? {
            type: "image",
            source: {
              type: "base64",
              media_type: data[1].toLowerCase() as "image/jpeg" | "image/png" | "image/gif" | "image/webp",
              data: data[2],
            },
          }
          : { type: "image", source: { type: "url", url: part.image_url.url } };
      });
      return { role: m.role as "user" | "assistant", content: blocks };
    })
    // Claude refuses an empty turn, and a conversation that opens with the
    // assistant -- which a "last six turns" slice of chat often does.
    .filter((m) => typeof m.content !== "string" || m.content.trim().length > 0);
  while (messages.length > 0 && messages[0].role === "assistant") messages.shift();

  return { system, messages };
}

function usageOf(message: Anthropic.Message): Completion["usage"] {
  const u = message.usage;
  const prompt = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
  const completion = u.output_tokens ?? 0;
  return { prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion };
}

function textOf(message: Anthropic.Message): string {
  return message.content.map((block) => (block.type === "text" ? block.text : "")).join("");
}

/** One answer, from Claude, or from OpenAI when Claude cannot. */
export async function write(request: WriterRequest): Promise<Completion> {
  const anthropic = request.prefer === "openai" ? null : claude();
  if (anthropic) {
    try {
      const { system, messages } = toClaude(request);
      const message = await anthropic.messages.create({
        model: CLAUDE_WRITER,
        max_tokens: request.maxTokens ?? 16000,
        system,
        messages,
        output_config: { effort: request.effort ?? "low" },
      });
      if (message.stop_reason === "refusal") throw new Error("claude declined");
      const text = textOf(message);
      if (!text.trim()) throw new Error("claude wrote nothing");
      return {
        model: message.model,
        usage: usageOf(message),
        choices: [{ message: { content: request.json ? jsonOnly(text) : text } }],
      };
    } catch (thrown) {
      console.warn("writer: claude failed, using openai", thrown instanceof Error ? thrown.message : thrown);
    }
  }
  return await openai(request);
}

/**
 * The same, streamed: `onText` gets each piece as it is written. Used by the
 * analytics answer, which the person watches arrive.
 */
export async function writeStreaming(request: WriterRequest, onText: (piece: string) => void): Promise<Completion> {
  const anthropic = request.prefer === "openai" ? null : claude();
  if (anthropic) {
    let wrote = false;
    try {
      const { system, messages } = toClaude(request);
      const stream = anthropic.messages.stream({
        model: CLAUDE_WRITER,
        max_tokens: request.maxTokens ?? 16000,
        system,
        messages,
        output_config: { effort: request.effort ?? "low" },
      });
      stream.on("text", (piece) => {
        if (piece) {
          wrote = true;
          onText(piece);
        }
      });
      const message = await stream.finalMessage();
      if (message.stop_reason === "refusal" && !wrote) throw new Error("claude declined");
      return { model: message.model, usage: usageOf(message), choices: [{ message: { content: textOf(message) } }] };
    } catch (thrown) {
      console.warn("writer: claude stream failed", thrown instanceof Error ? thrown.message : thrown);
      // Half an answer already on screen is kept; only a stream that never
      // started falls back.
      if (wrote) throw thrown;
    }
  }
  return await openaiStreaming(request, onText);
}

// ------------------------------------------------------------------ fallback

async function openai(request: WriterRequest): Promise<Completion> {
  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: request.openaiModel,
      ...(request.json ? { response_format: { type: "json_object" } } : {}),
      messages: request.messages,
    }),
  });
  const body = await response.json();
  if (!response.ok) throw new Error(`openai ${response.status}: ${JSON.stringify(body?.error ?? body).slice(0, 200)}`);
  return {
    model: body.model ?? request.openaiModel,
    usage: {
      prompt_tokens: body.usage?.prompt_tokens ?? 0,
      completion_tokens: body.usage?.completion_tokens ?? 0,
      total_tokens: body.usage?.total_tokens ?? 0,
    },
    choices: [{ message: { content: body.choices?.[0]?.message?.content ?? "" } }],
  };
}

async function openaiStreaming(request: WriterRequest, onText: (piece: string) => void): Promise<Completion> {
  const upstream = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${OPENAI_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: request.openaiModel,
      stream: true,
      stream_options: { include_usage: true },
      messages: request.messages,
    }),
  });
  if (!upstream.ok || !upstream.body) {
    throw new Error(`openai ${upstream.status}: ${(await upstream.text().catch(() => "")).slice(0, 200)}`);
  }
  const reader = upstream.body.getReader();
  const decoder = new TextDecoder();
  let buffered = "";
  let said = "";
  let usage: Completion["usage"] = { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 };
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffered += decoder.decode(value, { stream: true });
    const frames = buffered.split("\n\n");
    buffered = frames.pop() ?? "";
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
          said += delta;
          onText(delta);
        }
      } catch {
        // One unreadable frame is one frame; the answer continues.
      }
    }
  }
  return { model: request.openaiModel, usage, choices: [{ message: { content: said } }] };
}
