/**
 * A generic MCP client, and the adapter that turns any MCP server into a
 * provider.
 *
 * This is the file that makes the connector layer worth building. Higgsfield's
 * MCP server is not special -- it is an MCP server -- so implementing the
 * protocol once gets Higgsfield and every future MCP server at the same time.
 * Nothing below is Higgsfield-specific except one lookup table of tool names,
 * and that is data.
 *
 * Two structural facts about MCP shape everything here.
 *
 * The transport is JSON-RPC over HTTP, and a server may answer either as JSON
 * or as an SSE stream depending on what the client said it accepts. Both have
 * to be read, because which one you get is the server's choice, not ours.
 *
 * And a session has to be opened before anything else: `initialize`, then the
 * `notifications/initialized` acknowledgement, and the server hands back an
 * `Mcp-Session-Id` that every later call carries. Skipping it works against
 * some servers and fails against others, which is the worst kind of working.
 *
 * What is NOT here, deliberately: capabilities are read from `tools/list` and
 * never assumed. Two accounts on one provider expose different tools, exactly
 * as they expose different models, and a hardcoded list would be a promise the
 * agent makes and the provider then breaks.
 */

import {
  type Adapter,
  type Authorization,
  type Capability,
  type Discovery,
  type ModelDescriptor,
  type Polled,
  type Submitted,
  type SubmitRequest,
  unknownVerdict,
  type Verdict,
} from "./contract.ts";

const PROTOCOL_VERSION = "2025-06-18";

interface RpcResult {
  result?: Record<string, unknown>;
  error?: { code: number; message: string; data?: unknown };
}

interface McpTool {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
}

/** An open MCP session. Cheap to make and not worth caching across requests:
 *  the session id is server state we do not own, and a stale one fails in a way
 *  that looks like an auth problem. */
export class McpSession {
  private sessionId: string | null = null;
  private nextId = 1;

  constructor(private readonly endpoint: string, private readonly token: string) {}

  private headers(): Record<string, string> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.token}`,
      "Content-Type": "application/json",
      // Both, because the server picks. Sending only one is how a client works
      // against the server it was written for and nothing else.
      Accept: "application/json, text/event-stream",
      "MCP-Protocol-Version": PROTOCOL_VERSION,
    };
    if (this.sessionId) headers["Mcp-Session-Id"] = this.sessionId;
    return headers;
  }

  /** One JSON-RPC round trip. Throws `McpError` carrying the HTTP status, so
   *  `classify` upstream has something real to reason about. */
  async call(method: string, params?: Record<string, unknown>): Promise<Record<string, unknown>> {
    const response = await fetch(this.endpoint, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ jsonrpc: "2.0", id: this.nextId++, method, params: params ?? {} }),
    });

    // Captured on every response, not just initialize: a server is allowed to
    // start a session whenever it likes.
    const issued = response.headers.get("mcp-session-id");
    if (issued) this.sessionId = issued;

    const text = await response.text();

    if (!response.ok) {
      throw new McpError(response.status, text.slice(0, 400));
    }

    const payload = parseRpc(text);
    if (payload.error) {
      // A JSON-RPC error is an application refusal, not a transport failure.
      // Reported as 422 so it never looks like the provider being down.
      throw new McpError(422, payload.error.message ?? "the tool refused");
    }
    return payload.result ?? {};
  }

  /** Fire-and-forget, for `notifications/*`, which take no reply. */
  async notify(method: string): Promise<void> {
    await fetch(this.endpoint, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ jsonrpc: "2.0", method }),
    }).catch(() => {});
  }

  /** Opens the session. Must run before anything else. */
  async open(): Promise<Record<string, unknown>> {
    const result = await this.call("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "Autocast", version: "1.0" },
    });
    await this.notify("notifications/initialized");
    return result;
  }

  async tools(): Promise<McpTool[]> {
    const result = await this.call("tools/list");
    return (result.tools as McpTool[]) ?? [];
  }
}

export class McpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
    this.name = "McpError";
  }
}

/**
 * Reads a response that may be plain JSON or an SSE stream.
 *
 * The SSE form carries the JSON-RPC payload in `data:` lines, one frame per
 * message. Taking the LAST parseable frame rather than the first: a server may
 * send progress notifications ahead of the result, and the result is what was
 * asked for.
 */
function parseRpc(text: string): RpcResult {
  const trimmed = text.trim();
  if (trimmed.startsWith("{")) {
    try {
      return JSON.parse(trimmed) as RpcResult;
    } catch {
      return { error: { code: -1, message: "unreadable response" } };
    }
  }

  let last: RpcResult | null = null;
  for (const line of trimmed.split("\n")) {
    if (!line.startsWith("data:")) continue;
    const payload = line.slice(5).trim();
    if (!payload || payload === "[DONE]") continue;
    try {
      const parsed = JSON.parse(payload) as RpcResult;
      // Progress frames have neither; only keep something that answers.
      if (parsed.result !== undefined || parsed.error !== undefined) last = parsed;
    } catch {
      // One bad frame is one frame. Losing it beats failing the call.
    }
  }
  return last ?? { error: { code: -1, message: "no result in stream" } };
}

/**
 * Which tool means which capability, per provider.
 *
 * Data rather than branches, and the only provider-specific thing in this file.
 * Matched on the tool name a server actually reports, so a provider renaming a
 * tool shows up as a capability disappearing from discovery -- visible -- rather
 * than as generation failing later.
 */
const TOOL_CAPABILITIES: Record<string, Record<string, Capability>> = {
  higgsfield: {
    generate_video: "video_generation",
    generate_video_batch: "video_generation",
    generate_image: "image_generation",
    generate_image_batch: "image_generation",
    generate_audio: "audio_generation",
    generate_audio_batch: "audio_generation",
    create_voice: "voice_generation",
    dubbing: "audio_generation",
    voice_change: "voice_generation",
  },
};

/**
 * A tool that lists the models behind a capability, where the provider has one.
 *
 * Higgsfield needs this: its models are not tools, they are a `model` parameter
 * to `generate_video`. Seedance 2.5 and Kling are values, not endpoints. So
 * `tools/list` answers "can this account make video" and a second call answers
 * "with what" -- and a provider without such a tool simply gets one entry per
 * capability, which is honest rather than invented.
 */
const MODEL_CATALOGUE: Record<string, { tool: string; args: Record<string, unknown> }> = {
  higgsfield: { tool: "models_explore", args: { action: "list", limit: 100 } },
};

/** Reads whatever shape a catalogue tool returned. Providers disagree about
 *  where the list lives, so the plausible places are tried rather than one
 *  being assumed. */
function itemsFrom(payload: unknown): Array<Record<string, unknown>> {
  const content = (payload as { content?: Array<{ type: string; text?: string }> })?.content;
  if (Array.isArray(content)) {
    for (const part of content) {
      if (part.type === "text" && part.text) {
        try {
          const parsed = JSON.parse(part.text);
          const items = parsed.items ?? parsed.models ?? parsed.data;
          if (Array.isArray(items)) return items;
        } catch {
          // Not JSON in the text block. Nothing to read.
        }
      }
    }
  }
  const direct = (payload as { items?: unknown[]; models?: unknown[] });
  if (Array.isArray(direct?.items)) return direct.items as Array<Record<string, unknown>>;
  if (Array.isArray(direct?.models)) return direct.models as Array<Record<string, unknown>>;
  return [];
}

/**
 * Builds an adapter for one MCP-backed provider.
 *
 * The provider slug only picks the two lookup tables above; everything else is
 * protocol. Adding an MCP provider is a slug and, if its tool names are
 * unconventional, a row in TOOL_CAPABILITIES.
 */
export function mcpAdapter(slug: string): Adapter {
  return {
    slug,

    async discover(auth: Authorization): Promise<Discovery> {
      const session = new McpSession(auth.endpoint, auth.secret);
      const info = await session.open();

      const server = (info.serverInfo as { name?: string })?.name ?? slug;
      const tools = await session.tools();

      const map = TOOL_CAPABILITIES[slug] ?? {};
      const found = new Map<Capability, string>();
      for (const tool of tools) {
        const capability = map[tool.name];
        // First tool wins for a capability: the batch variants come after the
        // single ones and are the same thing at a different arity.
        if (capability && !found.has(capability)) found.set(capability, tool.name);
      }

      const models: ModelDescriptor[] = [];
      const catalogue = MODEL_CATALOGUE[slug];

      for (const [capability, toolName] of found) {
        let listed: Array<Record<string, unknown>> = [];

        if (catalogue && tools.some((t) => t.name === catalogue.tool)) {
          try {
            const result = await session.call("tools/call", {
              name: catalogue.tool,
              arguments: { ...catalogue.args, type: kindFor(capability) },
            });
            listed = itemsFrom(result);
          } catch {
            // A catalogue that will not answer is not a reason to report the
            // capability as absent -- the tool is there and it works. Fall
            // through to the single generic entry below.
          }
        }

        if (listed.length === 0) {
          models.push({
            capability,
            external_id: toolName,
            label: `${server} (best available)`,
            metadata: { tool: toolName, chosen_by: "provider" },
            rank: 0,
          });
          continue;
        }

        listed.forEach((item, index) => {
          const id = String(item.id ?? item.model_id ?? item.slug ?? item.name ?? "");
          if (!id) return;
          models.push({
            capability,
            external_id: id,
            label: String(item.name ?? item.title ?? id),
            metadata: {
              tool: toolName,
              // Kept whole. A chooser needs durations, aspect ratios and cost,
              // and normalising them here would mean a migration every time a
              // provider adds a knob.
              ...item,
            },
            rank: index,
          });
        });
      }

      return {
        accountLabel: String((info.serverInfo as { name?: string })?.name ?? server),
        externalAccountId: null,
        models,
      };
    },

    async submit(auth: Authorization, request: SubmitRequest): Promise<Submitted> {
      const session = new McpSession(auth.endpoint, auth.secret);
      await session.open();

      // The tool comes from what discovery recorded, not from a constant here.
      const tool = typeof request.options?.tool === "string"
        ? request.options.tool as string
        : request.model;

      const result = await session.call("tools/call", {
        name: tool,
        arguments: {
          prompt: request.prompt,
          // `model` only when discovery found a real catalogue; otherwise the
          // provider is choosing and passing its own tool name back as a model
          // would be nonsense.
          ...(request.model !== tool ? { model: request.model } : {}),
          ...(request.options ?? {}),
        },
      });

      // MCP tool calls are synchronous at the protocol level, but a generation
      // is not -- the tool returns a handle. Where a provider returns nothing
      // pollable, the content itself is the result and the job is already done.
      const handle = jobHandle(result);

      return handle
        ? { ref: handle, state: "running" }
        : { ref: crypto.randomUUID(), state: "done", statusUrl: undefined };
    },

    async poll(auth: Authorization, submitted: Submitted): Promise<Polled> {
      if (submitted.state === "done") return { state: "done" };

      const session = new McpSession(auth.endpoint, auth.secret);
      await session.open();

      try {
        const result = await session.call("tools/call", {
          name: "job_status",
          arguments: { job_id: submitted.ref },
        });
        const url = mediaUrl(result);
        if (url) return { state: "done", outputUrl: url };
        return { state: "running" };
      } catch (error) {
        if (error instanceof McpError) {
          return { state: "failed", verdict: this.classify(error.status, { detail: error.message }) };
        }
        throw error;
      }
    },

    classify(status: number, body: unknown): Verdict {
      const detail = typeof (body as { detail?: unknown })?.detail === "string"
        ? (body as { detail: string }).detail
        : String(status);

      // 401 on an MCP server means the token, and a token that has stopped
      // working is reconnected rather than retried -- there is no other model
      // or provider that fixes somebody's expired authorization.
      if (status === 401) {
        return {
          code: "needs_reconnect",
          retryable: false,
          tryAnotherModel: false,
          tryAnotherProvider: true,
          detail,
        };
      }
      if (status === 403) {
        return {
          code: /credit|balance|quota/i.test(detail) ? "no_credits" : "needs_reconnect",
          retryable: false,
          tryAnotherModel: false,
          tryAnotherProvider: true,
          detail,
        };
      }
      if (status === 429) {
        return { code: "rate_limited", retryable: true, tryAnotherModel: false, tryAnotherProvider: true, detail };
      }
      if (status === 404 || status === 422) {
        return { code: "no_models", retryable: false, tryAnotherModel: true, tryAnotherProvider: true, detail };
      }
      if (status >= 500) {
        return { code: "provider_down", retryable: true, tryAnotherModel: false, tryAnotherProvider: true, detail };
      }
      return unknownVerdict(status, detail);
    },
  };
}

/** Which slice of a model catalogue belongs to a capability. */
function kindFor(capability: Capability): string {
  if (capability === "video_generation") return "video";
  if (capability === "image_generation") return "image";
  if (capability === "voice_generation" || capability === "audio_generation") return "audio";
  return "video";
}

/** A job id, wherever the tool put it. */
function jobHandle(payload: unknown): string | null {
  const text = JSON.stringify(payload ?? {});
  const match = text.match(/"(?:job_id|jobId|id|request_id)"\s*:\s*"([^"]{8,})"/);
  return match ? match[1] : null;
}

/** A finished media URL, wherever the tool put it. Images and thumbnails are
 *  rejected here rather than downstream -- see `_shared/media.ts` for what a
 *  poster frame stored as a video would have cost. */
function mediaUrl(payload: unknown): string | null {
  const text = JSON.stringify(payload ?? {});
  const urls = [...text.matchAll(/"(https?:\/\/[^"]+)"/g)].map((m) => m[1]);
  const video = urls.find((u) => /\.(mp4|mov|webm|m4v)(\?|$)/i.test(u));
  return video ?? null;
}
