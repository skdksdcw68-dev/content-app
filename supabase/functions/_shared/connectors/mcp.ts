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
  type Cost,
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
 * When the table does not recognise a name, read it.
 *
 * The first real connection to Higgsfield discovered nothing: `tools/list`
 * answered, and not one name matched the table above, so the account came back
 * with zero capabilities and the person was told they were connected to
 * something that could do nothing.
 *
 * An exact-name table was the wrong shape for a claim of "any MCP server". Tool
 * names are prose written by whoever built the server, and the whole point of
 * this adapter is to meet servers nobody has met yet.
 *
 * So: the table is the override, and this is the default. It looks for a verb
 * that means "make one" and a noun that says what -- which is how these tools
 * are named across every MCP server worth connecting, because the names are
 * written for a model to read.
 *
 * Batch and variant forms are deliberately skipped: they are the same
 * capability at a different arity, and letting one win the slot means submitting
 * a single request to a tool expecting a list.
 */
function inferCapability(name: string, description = ""): Capability | null {
  const text = `${name} ${description}`.toLowerCase();
  const bare = name.toLowerCase();

  // Reading, listing, status and cost tools are not the thing itself. Without
  // this, `job_status` and `models_explore` look like generation.
  if (/(status|list|show|explore|search|get|describe|cancel|balance|cost|wait)/.test(bare)) {
    return null;
  }
  // Never, whatever its description says: anything that publishes, posts to a
  // platform, deploys, buys, or runs code. A tool reached by reading its name
  // must not be one whose side effect is outside "make a file" -- Higgsfield's
  // own server has `tiktok_publish` and `confirm_billing_purchase`.
  if (/(publish|post|tiktok|instagram|youtube|deploy|purchase|billing|trial|contest|delete|secret|sandbox|exec|website)/.test(bare)) {
    return null;
  }
  if (/(batch|multi|variant)/.test(bare)) return null;

  const makes = /(generate|create|make|render|produce|synthesi|compose)/.test(text);
  if (!makes) return null;

  // Order matters: voice before audio, because a voice tool almost always says
  // "audio" too and the more specific reading is the true one.
  if (/\bvoice\b|speech|tts|narrat/.test(text)) return "voice_generation";
  if (/\bvideo\b|clip|footage|motion/.test(text)) return "video_generation";
  if (/\bimage\b|photo|picture|art\b|visual/.test(text)) return "image_generation";
  if (/\baudio\b|music|sound|song/.test(text)) return "audio_generation";

  return null;
}

/**
 * A tool that lists the models behind a capability, where the provider has one.
 *
 * Higgsfield needs this: its models are not tools, they are a `model` parameter
 * to `generate_video`. Seedance 2.5 and Kling are values, not endpoints. So
 * `tools/list` answers "can this account make video" and a second call answers
 * "with what" -- and a provider without such a tool simply gets one entry per
 * capability, which is honest rather than invented.
 */
const MODEL_CATALOGUE: Record<string, {
  tool: string;
  args: Record<string, unknown>;
  /** Extra arguments that narrow the list to models needing no input file,
   *  where the catalogue offers such a filter. */
  textOnly?: Record<string, unknown>;
}> = {
  higgsfield: { tool: "models_explore", args: { action: "list", limit: 100 }, textOnly: { input: "text" } },
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
      // Table first, then read the name -- in two passes, so the table's
      // choice wins regardless of the order the server listed its tools in.
      // See `primaryTools`.
      const found = new Map<Capability, string>();
      for (const [capability, tool] of primaryTools(tools, slug)) found.set(capability, tool.name);

      const models: ModelDescriptor[] = [];
      const catalogue = MODEL_CATALOGUE[slug];

      // Each catalogue slice is asked for once, and each model recorded once.
      // Audio and voice both read the "audio" slice, so without this the same
      // model arrived twice in one write and the database refused the whole
      // list -- which is how the first real sign-in ended up with none.
      const slices = new Map<string, Array<Record<string, unknown>>>();
      const seen = new Set<string>();

      // Video and image first: they are what this product makes, so when a
      // model could belong to two capabilities it lands in the one that matters.
      const order: Capability[] = ["video_generation", "image_generation", "audio_generation", "voice_generation"];
      const ordered = [...found].sort(([a], [b]) =>
        (order.indexOf(a) + 1 || 99) - (order.indexOf(b) + 1 || 99)
      );

      for (const [capability, toolName] of ordered) {
        let listed: Array<Record<string, unknown>> = [];
        const kind = kindFor(capability);

        if (catalogue && tools.some((t) => t.name === catalogue.tool)) {
          if (!slices.has(kind)) {
            try {
              const result = await session.call("tools/call", {
                name: catalogue.tool,
                arguments: { ...catalogue.args, type: kind },
              });
              const items = itemsFrom(result);

              // The models that take no picture at all, which are certain to
              // work from words. Only ever marks a model TRUE: the filter means
              // "no picture input", not "works without one", and treating the
              // rest as unable would hide GPT Image and Seedance. See suits.ts.
              if (catalogue.textOnly && items.length > 0) {
                try {
                  const textResult = await session.call("tools/call", {
                    name: catalogue.tool,
                    arguments: { ...catalogue.args, type: kind, ...catalogue.textOnly },
                  });
                  const textIds = new Set(
                    itemsFrom(textResult).map((item) => String(item.id ?? item.model_id ?? item.slug ?? item.name ?? "")),
                  );
                  for (const item of items) {
                    const id = String(item.id ?? item.model_id ?? item.slug ?? item.name ?? "");
                    if (textIds.has(id)) item.text_only = true;
                  }
                } catch (thrown) {
                  console.error("catalogue text-only", kind, thrown instanceof Error ? thrown.message : thrown);
                }
              }

              slices.set(kind, items);
            } catch (thrown) {
              // A catalogue that will not answer is not a reason to report the
              // capability as absent -- the tool is there and it works. Fall
              // through to the single generic entry below.
              console.error("catalogue", kind, thrown instanceof Error ? thrown.message : thrown);
              slices.set(kind, []);
            }
          }
          listed = (slices.get(kind) ?? []).filter((item) => {
            const id = String(item.id ?? item.model_id ?? item.slug ?? item.name ?? "");
            return id && !seen.has(id);
          });
        }

        if (listed.length === 0) {
          if (seen.has(toolName)) continue;
          seen.add(toolName);
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
          if (!id || seen.has(id)) return;
          seen.add(id);
          models.push({
            capability,
            external_id: id,
            label: String(item.name ?? item.title ?? id),
            metadata: {
              // Kept whole. A chooser needs durations, aspect ratios and cost,
              // and normalising them here would mean a migration every time a
              // provider adds a knob.
              ...item,
              // After the spread, so a catalogue field called `tool` cannot
              // redirect the request to some other tool.
              tool: toolName,
            },
            rank: index,
          });
        });
      }

      return {
        accountLabel: String((info.serverInfo as { name?: string })?.name ?? server),
        externalAccountId: null,
        models,
        // Every tool, mapped or not. Descriptions trimmed: they are prose
        // written for a model to read and can run long, and this is for a
        // person diagnosing a connection, not for the model.
        tools: tools.map((tool) => ({
          name: tool.name,
          description: (tool.description ?? "").slice(0, 280),
          capability: map[tool.name] ?? inferCapability(tool.name, tool.description),
        })),
      };
    },

    async submit(auth: Authorization, request: SubmitRequest): Promise<Submitted> {
      const session = new McpSession(auth.endpoint, auth.secret);
      await session.open();
      const tools = await session.tools();

      const tool = toolFor(tools, request, slug);
      if (!tool) throw new McpError(404, `no tool for ${request.capability}`);

      const medias = await importReferences(session, tools, request);
      const args = argumentsFor(tool, request, medias, { spend: true });

      const result = checked(await session.call("tools/call", { name: tool.name, arguments: args }));

      // MCP tool calls are synchronous at the protocol level, but a generation
      // is not -- the tool returns a handle. A tool that answered with the
      // finished file instead is done now, and saying "running" would make the
      // worker poll for something it already has.
      const handle = jobHandle(result);
      const immediate = mediaUrl(result, request.capability);

      if (handle) return { ref: handle, state: "running", capability: request.capability };
      if (immediate) {
        return { ref: crypto.randomUUID(), state: "done", capability: request.capability, outputUrl: immediate };
      }
      throw new McpError(422, "the tool answered with neither a job nor a result");
    },

    async poll(auth: Authorization, submitted: Submitted): Promise<Polled> {
      if (submitted.state === "done") {
        return submitted.outputUrl
          ? { state: "done", outputUrl: submitted.outputUrl }
          : { state: "failed", verdict: badOutput("finished without a file") };
      }

      const session = new McpSession(auth.endpoint, auth.secret);
      await session.open();
      const tools = await session.tools();

      // The status tool is found, not named -- and found narrowly. Higgsfield
      // alone has seven tools with "status" in the name, one of them
      // `tiktok_publish_status`; "the first one that says status" could have
      // meant polling a publish. Only a tool about JOBS qualifies, and nothing
      // else is used as a fallback. Its argument name is read off its schema:
      // Higgsfield calls it `jobId`, and the previous version sent `job_id`,
      // which would have failed every poll of every job.
      const status = findJobStatusTool(tools);
      if (!status) {
        return { state: "failed", verdict: badOutput("the provider offers no way to check a job") };
      }
      const idKey = requiredKeys(status)[0];
      const args: Record<string, unknown> = { [idKey]: submitted.ref };
      // Where the server offers to wait a little before answering, let it: an
      // image is usually done inside that window, so the first poll finishes
      // the job instead of the third.
      if (hasProperty(status, "sync")) args.sync = true;

      try {
        const result = checked(await session.call("tools/call", { name: status.name, arguments: args }));
        const state = jobState(result);

        if (state === "refused") {
          return { state: "failed", verdict: { ...badOutput("the provider refused the prompt"), code: "refused" } };
        }
        if (state === "failed") {
          return { state: "failed", verdict: this.classify(422, { detail: textOf(result).slice(0, 300) }) };
        }

        const url = mediaUrl(result, submitted.capability);
        if (url) return { state: "done", outputUrl: url, outputMime: mimeFor(url, submitted.capability) };
        if (state === "done") {
          return { state: "failed", verdict: badOutput("finished without a file we can use") };
        }
        return { state: state === "queued" ? "queued" : "running" };
      } catch (error) {
        if (error instanceof McpError) {
          return { state: "failed", verdict: this.classify(error.status, { detail: error.message }) };
        }
        throw error;
      }
    },

    async quote(auth: Authorization, request: SubmitRequest): Promise<Cost | null> {
      const session = new McpSession(auth.endpoint, auth.secret);
      await session.open();
      const tools = await session.tools();

      const tool = toolFor(tools, request, slug);
      // A provider whose tool has no dry-run flag cannot be asked the price
      // without being asked to do the work. Null, not a guess.
      if (!tool || !hasProperty(tool, "get_cost")) return null;

      const args = argumentsFor(tool, request, [], { spend: false });
      const result = checked(await session.call("tools/call", { name: tool.name, arguments: args }));
      const credits = numberNamed(result, ["credits_exact", "credits", "credit_cost", "total_cost", "price", "cost"]);
      return credits === null ? null : { unit: "credits", amount: credits, quoted: true, basis: "for this request" };
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

// ------------------------------------------------------------------ requests

/** The tool that does this capability: the one discovery recorded for the
 *  model, else the one the table or the name-reading picks. */
function toolFor(tools: McpTool[], request: SubmitRequest, slug: string): McpTool | null {
  const recorded = request.metadata?.tool;
  if (typeof recorded === "string") {
    const hit = tools.find((t) => t.name === recorded);
    if (hit) return hit;
  }
  return primaryTools(tools, slug).get(request.capability) ?? null;
}

/**
 * One tool per capability: the table's choice first, the name-reading second.
 *
 * Two passes, because list order is the server's and means nothing. In one
 * pass, whichever tool came first claimed the slot -- and `upscale_image` or
 * `generate_3d` ("from an image") listed before `generate_image` would have
 * become the image generator, so "make me a picture" upscaled nothing.
 */
function primaryTools(tools: McpTool[], slug: string): Map<Capability, McpTool> {
  const map = TOOL_CAPABILITIES[slug] ?? {};
  const single = tools.filter((t) => !/(batch|multi|variant)/i.test(t.name));
  const found = new Map<Capability, McpTool>();

  for (const tool of single) {
    const capability = map[tool.name];
    if (capability && !found.has(capability)) found.set(capability, tool);
  }
  for (const tool of single) {
    if (map[tool.name]) continue;
    const capability = inferCapability(tool.name, tool.description);
    if (capability && !found.has(capability)) found.set(capability, tool);
  }
  return found;
}

/** The tool that reports on a generation job, and only that. */
function findJobStatusTool(tools: McpTool[]): McpTool | null {
  const candidates = tools.filter((t) =>
    /status/i.test(t.name) &&
    requiredKeys(t).length >= 1 &&
    // Never anything about publishing, posting or an outside platform.
    !/(publish|post|tiktok|instagram|youtube|website|deploy)/i.test(t.name)
  );
  return candidates.find((t) => /^jobs?_?status$/i.test(t.name)) ??
    candidates.find((t) => /job/i.test(t.name) && requiredKeys(t).some((k) => /job/i.test(k))) ??
    null;
}

type Schema = Record<string, unknown>;

/** Where a tool's real arguments live. Some servers take them flat, and some
 *  -- Higgsfield among them -- take one `params` object holding everything.
 *  Read off the schema the server published rather than assumed either way. */
function argumentShape(tool: McpTool): { wrapped: boolean; props: Record<string, Schema> } {
  const props = ((tool.inputSchema ?? {}).properties ?? {}) as Record<string, Schema>;
  const params = props.params;
  if (params) {
    const variants = (params.anyOf ?? params.oneOf ?? [params]) as Schema[];
    const object = variants.find((v) => v.type === "object" || v.properties) ?? {};
    return { wrapped: true, props: (object.properties ?? {}) as Record<string, Schema> };
  }
  return { wrapped: false, props };
}

function hasProperty(tool: McpTool, key: string): boolean {
  return key in argumentShape(tool).props;
}

function requiredKeys(tool: McpTool): string[] {
  const required = (tool.inputSchema ?? {}).required;
  return Array.isArray(required) ? required.map(String) : [];
}

/**
 * One request, shaped to exactly what the tool says it takes.
 *
 * Only keys the schema names are sent. A request padded with fields the tool
 * never declared is one a strict server rejects and a lax one silently ignores
 * -- and either way the person gets something other than what they asked for.
 */
function argumentsFor(
  tool: McpTool,
  request: SubmitRequest,
  medias: Array<{ value: string; role: string }>,
  { spend }: { spend: boolean },
): Record<string, unknown> {
  const { wrapped, props } = argumentShape(tool);
  const args: Record<string, unknown> = {};

  // `model` only when discovery found a real catalogue; when the tool itself
  // was recorded as the model, the provider is choosing.
  if ("model" in props && request.model !== tool.name) args.model = request.model;
  if ("prompt" in props) args.prompt = request.prompt;

  for (const [key, value] of Object.entries(request.options ?? {})) {
    if (value === undefined || value === null) continue;
    if (key in props) {
      args[key] = value;
      continue;
    }
    // A setting the TOOL does not declare but the chosen MODEL does -- "2k
    // resolution" on Nano Banana Pro. Higgsfield takes model settings at the
    // top level of `params`, and lists each model's own in its catalogue entry.
    // Sent only as one of the values the model accepts, spelled its way.
    const declared = modelParameter(request.metadata, key);
    if (!declared) continue;
    const accepted = coerce(value, declared);
    if (accepted !== undefined) args[key] = accepted;
  }

  if (medias.length > 0 && "medias" in props) args.medias = medias;
  if ("count" in props) args.count = 1;

  if (!spend && "get_cost" in props) args.get_cost = true;
  // Paid from credits, which is what the person agreed to when they chose the
  // model. A free-trial allowance is spent only when somebody explicitly says
  // so -- and leaving this unset makes Higgsfield answer with a question
  // instead of a job, which a worker with nobody to ask would read as failure.
  if (spend && "use_unlim" in props) args.use_unlim = false;

  return wrapped ? { params: args } : args;
}

type ModelParameter = { name?: unknown; options?: unknown; min?: unknown; max?: unknown; type?: unknown };

/** One of the chosen model's own settings, from its catalogue entry. */
function modelParameter(metadata: Record<string, unknown> | undefined, key: string): ModelParameter | null {
  const list = Array.isArray(metadata?.parameters) ? metadata!.parameters as ModelParameter[] : [];
  return list.find((p) => p.name === key) ?? null;
}

/** A requested value as the model spells it, or undefined when it has no
 *  such value. "2K" becomes "2k"; "8k" on a model that stops at 4k is dropped
 *  rather than sent to be refused. */
function coerce(value: unknown, declared: ModelParameter): unknown {
  if (Array.isArray(declared.options) && declared.options.length > 0) {
    const wanted = String(value).toLowerCase().replace(/\s+/g, "");
    return declared.options.find((option) => String(option).toLowerCase().replace(/\s+/g, "") === wanted);
  }
  if (declared.type === "number" || typeof declared.min === "number" || typeof declared.max === "number") {
    const n = Number(value);
    if (!Number.isFinite(n)) return undefined;
    if (typeof declared.min === "number" && n < declared.min) return declared.min;
    if (typeof declared.max === "number" && n > declared.max) return declared.max;
    return n;
  }
  return value;
}

/** Hands each reference to the provider and returns what its tool wants in
 *  `medias`. Something the provider already made goes by its own handle; a file
 *  of ours goes by a short-lived signed link through its import tool. */
async function importReferences(
  session: McpSession,
  tools: McpTool[],
  request: SubmitRequest,
): Promise<Array<{ value: string; role: string }>> {
  const out: Array<{ value: string; role: string }> = [];

  for (const reference of request.references ?? []) {
    const role = roleFor(request.metadata, reference.kind, out.length);

    if (reference.providerRef) {
      out.push({ value: reference.providerRef, role });
      continue;
    }
    if (!reference.url) continue;

    // The media importer specifically -- a 3D scene builder also "imports",
    // and a reference handed to the wrong importer is a reference lost.
    const importers = tools.filter((t) => /import/i.test(t.name) && hasProperty(t, "url"));
    const importer = importers.find((t) => /media/i.test(t.name)) ??
      importers.find((t) => /url/i.test(t.name) && !/(scene|3d|website)/i.test(t.name));
    if (!importer) throw new McpError(422, "this provider cannot take a reference by link");

    const args: Record<string, unknown> = { url: reference.url };
    if (hasProperty(importer, "type")) args.type = reference.kind;

    const result = checked(await session.call("tools/call", { name: importer.name, arguments: args }));
    const id = firstUuid(result, ["media_id", "mediaId", "id"]);
    if (!id) throw new McpError(422, "the reference did not import");
    out.push({ value: id, role });
  }

  return out;
}

/** Which role a reference plays for this model. Read from the catalogue entry
 *  discovery stored, because the names differ per model -- a start frame on one
 *  is an "image" on another. The kind itself is the last resort; the server
 *  coerces it when there is only one sensible reading. */
function roleFor(metadata: Record<string, unknown> | undefined, kind: "image" | "video", index: number): string {
  const roles = new Set<string>();
  const walk = (value: unknown, key?: string) => {
    if (Array.isArray(value)) {
      if (key === "roles") {
        for (const item of value) {
          if (typeof item === "string") roles.add(item);
          else if (item && typeof item === "object") {
            const named = (item as { role?: unknown; name?: unknown }).role ??
              (item as { name?: unknown }).name;
            if (typeof named === "string") roles.add(named);
          }
        }
      } else value.forEach((item) => walk(item));
    } else if (value && typeof value === "object") {
      for (const [k, v] of Object.entries(value)) walk(v, k);
    }
  };
  walk(metadata ?? {});

  const list = [...roles];
  const preferred = kind === "image"
    ? [/start|first/i, /^image$/i, /image/i, /reference|ref/i]
    : [/driving|source/i, /video/i];
  for (const pattern of preferred) {
    const hit = list.find((role) => pattern.test(role));
    if (hit) return hit;
  }
  return list[index] ?? kind;
}

// ------------------------------------------------------------------ answers

/** A tool that reported failure inside a successful RPC. MCP carries tool
 *  errors as `isError` content rather than as JSON-RPC errors, so without this
 *  an empty balance would look like a job with no id. */
function checked(result: Record<string, unknown>): Record<string, unknown> {
  if (result.isError !== true) return result;
  const text = textOf(result);
  const status = /credit|balance|insufficient|top.?up|upgrade/i.test(text)
    ? 403
    : /unauthori[sz]ed|expired|sign.?in|token/i.test(text)
    ? 401
    : 422;
  throw new McpError(status, text.slice(0, 300));
}

/** Every structured thing in a tool result: `structuredContent`, and any text
 *  block that is JSON. Providers put the useful part in either. */
function objectsIn(result: unknown): unknown[] {
  const found: unknown[] = [];
  const r = result as { structuredContent?: unknown; content?: Array<{ type: string; text?: string }> };
  if (r?.structuredContent) found.push(r.structuredContent);
  for (const part of r?.content ?? []) {
    if (part.type !== "text" || !part.text) continue;
    try {
      found.push(JSON.parse(part.text));
    } catch {
      // Prose. Still searched as text by the callers that need it.
    }
  }
  found.push(result);
  return found;
}

function textOf(result: unknown): string {
  const r = result as { structuredContent?: unknown; content?: Array<{ type: string; text?: string }> };
  const parts = (r?.content ?? []).filter((p) => p.type === "text" && p.text).map((p) => p.text as string);
  if (r?.structuredContent) parts.push(JSON.stringify(r.structuredContent));
  return parts.join("\n");
}

/** Every (key, value) pair anywhere in a result, depth first. */
function* entries(value: unknown, key = ""): Generator<[string, unknown]> {
  if (Array.isArray(value)) {
    for (const item of value) yield* entries(item, key);
  } else if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) {
      yield [k, v];
      yield* entries(v, k);
    }
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The first UUID under one of `keys`, tried in order -- so `job_id` wins over
 *  a bare `id` that might belong to the model or the workspace. */
function firstUuid(result: unknown, keys: string[]): string | null {
  const objects = objectsIn(result);
  for (const wanted of keys) {
    for (const object of objects) {
      for (const [k, v] of entries(object)) {
        if (k !== wanted) continue;
        if (typeof v === "string" && UUID.test(v)) return v;
        if (Array.isArray(v)) {
          const hit = v.find((x) => typeof x === "string" && UUID.test(x));
          if (hit) return hit as string;
        }
      }
    }
  }
  return null;
}

/** A job id, wherever the tool put it. UUIDs only: Higgsfield's status tool
 *  refuses anything else, and a model name matched as an id would be polled
 *  forever. */
function jobHandle(result: unknown): string | null {
  return firstUuid(result, ["job_id", "jobId", "job_ids", "jobIds", "generation_id", "request_id", "id"]);
}

type JobState = "queued" | "running" | "done" | "failed" | "refused";

function jobState(result: unknown): JobState {
  for (const object of objectsIn(result)) {
    for (const [k, v] of entries(object)) {
      if ((k !== "status" && k !== "state") || typeof v !== "string") continue;
      const s = v.toLowerCase();
      if (/nsfw|refus|moderat|block/.test(s)) return "refused";
      if (/fail|error|cancel/.test(s)) return "failed";
      if (/complet|succe|done|finish|ready/.test(s)) return "done";
      if (/queue|pending|wait|created/.test(s)) return "queued";
      return "running";
    }
  }
  return "running";
}

const EXTENSIONS = {
  video: /\.(mp4|mov|webm|m4v)(\?|$)/i,
  image: /\.(png|jpe?g|webp)(\?|$)/i,
  audio: /\.(mp3|wav|m4a|aac|ogg)(\?|$)/i,
};

/** A finished file's URL, of the kind that was asked for. Thumbnails and
 *  posters are passed over -- see `_shared/media.ts` for what a poster frame
 *  stored as a video would have cost. */
function mediaUrl(result: unknown, capability: Capability | undefined): string | null {
  const kind = capability === "image_generation"
    ? "image"
    : capability === "audio_generation" || capability === "voice_generation"
    ? "audio"
    : "video";

  // Every URL, with the full path it was found under. The path matters more
  // than the link: Higgsfield's finished job carries THREE image URLs --
  // `results.rawUrl` (the file), `results.minUrl` (a preview) and
  // `params.style.url` (the example picture for the style it used) -- and the
  // first real image saved was the style's example, because it came first.
  const found: Array<{ path: string[]; url: string }> = [];
  const r = result as { content?: Array<Record<string, unknown>> };
  for (const part of r?.content ?? []) {
    // MCP's own way of saying "here is the file".
    if (part.type === "resource_link" && typeof part.uri === "string") found.push({ path: ["resource_link"], url: part.uri });
  }
  for (const object of objectsIn(result)) {
    for (const [path, v] of walk(object)) {
      if (typeof v === "string" && /^https?:\/\//.test(v)) found.push({ path, url: v });
    }
  }
  // Links in prose only when there is nothing structured -- prose has no
  // paths, so it cannot tell the file from a preview or a style sample.
  const pool = found.length > 0
    ? found
    : [...textOf(result).matchAll(/https?:\/\/[^\s"'<>\\)]+/g)].map((m) => ({ path: [] as string[], url: m[0] }));

  const otherKinds = Object.entries(EXTENSIONS).filter(([k]) => k !== kind).map(([, re]) => re);
  // Anything inside what was ASKED for is an input, not the output.
  const inputSegment = /^(params|parameters|request|input|inputs|style|styles|reference|references|medias|avatars?|presets?)$/i;
  const decoyKey = /(thumb|poster|preview|cover|avatar|^min|min_?url$|_min$|small|blur)/i;
  const decoyUrl = /(thumb|poster|preview|_min\.|\/min\/)/i;

  let best: { url: string; score: number } | null = null;
  for (const candidate of pool) {
    const key = candidate.path[candidate.path.length - 1] ?? "";
    const parents = candidate.path.slice(0, -1);
    if (parents.some((segment) => inputSegment.test(segment))) continue;
    if (decoyKey.test(key) || decoyUrl.test(candidate.url)) continue;
    if (otherKinds.some((re) => re.test(candidate.url))) continue;

    let score = 0;
    if (/(raw|original|full|final)/i.test(key)) score += 100;
    if (candidate.path[0] === "resource_link") score += 80;
    if (parents.some((segment) => /^(results?|outputs?|generations?|images|videos|files|assets)$/i.test(segment))) score += 50;
    if (new RegExp(kind, "i").test(key)) score += 30;
    if (EXTENSIONS[kind].test(candidate.url)) score += 20;
    if (/^(url|uri|src|href)$/i.test(key)) score += 5;

    // Some evidence is required. A bare link under an unknown key with no
    // extension is as likely a help page as a file.
    if (score >= 20 && (!best || score > best.score)) best = { url: candidate.url, score };
  }
  return best?.url ?? null;
}

/** Every (path, value) pair anywhere in a result, depth first. */
function* walk(value: unknown, path: string[] = []): Generator<[string[], unknown]> {
  if (Array.isArray(value)) {
    for (const item of value) yield* walk(item, path);
  } else if (value && typeof value === "object") {
    for (const [k, v] of Object.entries(value)) {
      const next = [...path, k];
      yield [next, v];
      yield* walk(v, next);
    }
  }
}

function mimeFor(url: string, capability: Capability | undefined): string {
  const ext = url.split("?")[0].split(".").pop()?.toLowerCase() ?? "";
  const known: Record<string, string> = {
    mp4: "video/mp4", mov: "video/quicktime", webm: "video/webm", m4v: "video/mp4",
    png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp",
    mp3: "audio/mpeg", wav: "audio/wav", m4a: "audio/mp4",
  };
  if (known[ext]) return known[ext];
  return capability === "image_generation" ? "image/png" : "video/mp4";
}

/** A number under one of `names`, tried IN THAT ORDER, or in prose as "N
 *  credits". Order matters: Higgsfield answers a price check with
 *  `{cost: {credits: 1, credits_exact: 0.5}}`, and balances are fractional,
 *  so the exact figure is what is actually deducted. */
function numberNamed(result: unknown, names: string[]): number | null {
  const objects = objectsIn(result);
  for (const name of names) {
    for (const object of objects) {
      for (const [k, v] of entries(object)) {
        if (k !== name) continue;
        const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
        if (Number.isFinite(n)) return n;
      }
    }
  }
  const prose = textOf(result).match(/(\d+(?:\.\d+)?)\s*credits?/i);
  return prose ? Number(prose[1]) : null;
}

function badOutput(detail: string): Verdict {
  return { code: "bad_output", retryable: false, tryAnotherModel: true, tryAnotherProvider: true, detail };
}

/** The pure parts, for the offline test against Higgsfield's real tool list.
 *  Nothing calls this at runtime. */
export const __test = {
  primaryTools,
  findJobStatusTool,
  argumentsFor,
  jobHandle,
  jobState,
  mediaUrl,
  numberNamed,
  roleFor,
  inferCapability,
};
