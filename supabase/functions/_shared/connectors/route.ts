/**
 * Turning "make me a video" into a provider that can, without naming one.
 *
 * This is the function the rest of the system calls. Everything above it says
 * what it wants; everything below it knows who can do it. `generate.ts` used to
 * open with `import { submit } from "./higgsfield.ts"` -- this is what replaces
 * that line, and the difference is that a second provider is now a row in a
 * table rather than an `if` in the generation pipeline.
 *
 * The recovery ladder is the other half of the point. A single provider means
 * one refusal ends the day, which is exactly what happened in September: one
 * 404 from one model, and thirty scheduled posts quietly produced nothing. With
 * a registry the ladder is:
 *
 *   this model fails       -> the next model on the same connection
 *   the connection fails   -> the next provider that has the capability
 *   everything refuses     -> say precisely what is missing, once
 *
 * Each rung is taken only when the adapter's verdict says it is worth taking.
 * Retrying an empty balance on four models spends four requests to learn the
 * same thing.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { adapterFor } from "./registry.ts";
import { openConnection } from "./tokens.ts";
import { suits } from "./suits.ts";
import type { Capability, Cost, Submitted, SubmitRequest, Verdict } from "./contract.ts";

/** One candidate: a model, on a connection, reachable by an adapter. */
interface Candidate {
  modelId: string;
  connectionId: string;
  providerSlug: string;
  authKind: string;
  endpoint: string;
  externalId: string;
  label: string;
  metadata: Record<string, unknown>;
}

export interface RoutedSubmission {
  submitted: Submitted;
  connectionId: string;
  providerSlug: string;
  model: string;
  modelLabel: string;
}

export class NothingCanDoThis extends Error {
  constructor(
    message: string,
    /** The last real reason, so the caller can store a code rather than prose. */
    readonly code: string,
    /** What was tried, for the job row. Never shown to a person as-is. */
    readonly attempts: string[],
  ) {
    super(message);
    this.name = "NothingCanDoThis";
  }
}

/** Everything this person could use for one capability, best first. */
export async function candidatesFor(
  admin: SupabaseClient,
  userId: string,
  capability: Capability,
): Promise<Candidate[]> {
  const { data, error } = await admin.rpc("capabilities_for", {
    p_capability: capability,
    p_user: userId,
  });
  if (error) throw error;

  const rows = (data ?? []) as Array<{
    model_id: string;
    connection_id: string;
    provider_slug: string;
    external_id: string;
    label: string;
    metadata: Record<string, unknown>;
  }>;

  if (rows.length === 0) return [];

  // The auth kind and endpoint live on the connection, and the same connection
  // usually backs several models -- so they are read once each rather than per
  // candidate.
  const connectionIds = [...new Set(rows.map((row) => row.connection_id))];
  const details = new Map<string, { authKind: string; endpoint: string }>();

  for (const id of connectionIds) {
    const { data: read } = await admin.rpc("read_connection", { p_connection: id });
    const connection = (read ?? [])[0];
    if (!connection) continue;
    details.set(id, {
      authKind: connection.auth_kind,
      // Which door decides which address. `mcp_url ?? api_base` looks harmless
      // and hands a REST adapter the MCP endpoint the moment a provider has
      // both -- which Higgsfield now does, being reachable either way.
      endpoint: connection.auth_kind === "api_key"
        ? (connection.api_base ?? "")
        : (connection.mcp_url ?? connection.api_base ?? ""),
    });
  }

  const candidates = rows.flatMap((row) => {
    const detail = details.get(row.connection_id);
    if (!detail) return [];
    return [{
      modelId: row.model_id,
      connectionId: row.connection_id,
      providerSlug: row.provider_slug,
      authKind: detail.authKind,
      endpoint: detail.endpoint,
      externalId: row.external_id,
      label: row.label,
      metadata: row.metadata ?? {},
    }];
  });

  // A signed-in account before a pasted key, keeping each group's own order.
  // Somebody who signed in did so to stop using the key; and the key's models
  // are typed constants while a signed-in account's are discovered.
  return candidates.sort((a, b) => Number(a.authKind === "api_key") - Number(b.authKind === "api_key"));
}

/** The sealed credential for one connection, opened -- and refreshed first when
 *  it is about to expire. Never returned upward. */
async function secretFor(admin: SupabaseClient, connectionId: string): Promise<string> {
  return (await openConnection(admin, connectionId)).secret;
}

/** Asks a model what one request would cost, before anything is spent.
 *
 *  Only adapters whose provider will say implement `quote`; everyone else
 *  answers null, which the chat shows as "Cost not stated" rather than as a
 *  guess. */
export async function quoteFor(
  admin: SupabaseClient,
  args: { connectionId: string; capability: Capability; model: string; prompt: string; options?: Record<string, unknown> },
): Promise<Cost | null> {
  try {
    const opened = await openConnection(admin, args.connectionId);
    const adapter = adapterFor(opened.providerSlug, opened.authKind);
    if (!adapter.quote) return null;
    return await adapter.quote(
      { connectionId: args.connectionId, secret: opened.secret, endpoint: opened.endpoint },
      { capability: args.capability, model: args.model, prompt: args.prompt, options: args.options },
    );
  } catch {
    // A quote that fails is a quote nobody has, not a reason to stop.
    return null;
  }
}

/**
 * Submits to the best thing that will take it.
 *
 * `preferModel` is a preference and never a constraint. Somebody who chose Sora
 * in chat should get Sora if it works -- and should still get a video if Sora
 * has since been withdrawn from their account, rather than a failure explaining
 * that their choice is unavailable.
 */
export async function routeSubmit(
  admin: SupabaseClient,
  args: {
    userId: string;
    capability: Capability;
    prompt: string;
    options?: Record<string, unknown>;
    webhookUrl?: string;
    preferModel?: string;
    references?: SubmitRequest["references"];
  },
): Promise<RoutedSubmission> {
  const everything = await candidatesFor(admin, args.userId, args.capability);
  // The ladder only climbs models that can do this request -- a background
  // remover is not a fallback for "make an image". Unfiltered if the filter
  // would empty it, for the same reason as in `choicesFor`.
  const withPicture = (args.references?.length ?? 0) > 0;
  const able = everything.filter((c) => suits(c.metadata, withPicture));
  const all = able.length > 0 ? able : everything;

  if (all.length === 0) {
    throw new NothingCanDoThis(
      `Nothing you have connected can make ${readable(args.capability)} yet.`,
      "no_models",
      [],
    );
  }

  const ordered = args.preferModel
    ? [
      ...all.filter((c) => c.externalId === args.preferModel),
      ...all.filter((c) => c.externalId !== args.preferModel),
    ]
    : all;

  const attempts: string[] = [];
  let lastCode = "no_models";
  let blockedConnections = new Set<string>();

  for (const candidate of ordered) {
    // A connection whose credential or balance already refused is not asked
    // again on a different model of its own. That is the difference between a
    // ladder and a loop.
    if (blockedConnections.has(candidate.connectionId)) continue;

    try {
      const adapter = adapterFor(candidate.providerSlug, candidate.authKind);
      const secret = await secretFor(admin, candidate.connectionId);

      const submitted = await adapter.submit(
        { connectionId: candidate.connectionId, secret, endpoint: candidate.endpoint },
        {
          capability: args.capability,
          model: candidate.externalId,
          prompt: args.prompt,
          options: { ...candidate.metadata.defaults as Record<string, unknown>, ...args.options },
          metadata: candidate.metadata,
          references: args.references,
          webhookUrl: args.webhookUrl,
        },
      );

      return {
        submitted,
        connectionId: candidate.connectionId,
        providerSlug: candidate.providerSlug,
        model: candidate.externalId,
        modelLabel: candidate.label,
      };
    } catch (thrown) {
      const verdict = verdictOf(thrown, candidate.providerSlug, candidate.authKind);
      attempts.push(`${candidate.label}: ${verdict.code}`);
      lastCode = verdict.code;

      // Told by the adapter, not guessed here. `no_credits` and `bad_key` are
      // facts about the account, so every other model on it would answer the
      // same way; `no_models` is about this model alone.
      if (!verdict.tryAnotherModel) blockedConnections.add(candidate.connectionId);

      // A connection that needs reconnecting is worth saying so about, once,
      // where the person will see it.
      if (verdict.code === "needs_reconnect" || verdict.code === "bad_key") {
        await admin.rpc("fault_connection", {
          p_connection: candidate.connectionId,
          p_code: verdict.code,
          p_status: "expired",
        });
      }

      if (!verdict.tryAnotherProvider && !verdict.tryAnotherModel) break;
    }
  }

  throw new NothingCanDoThis(
    `None of your connected providers could make ${readable(args.capability)}.`,
    lastCode,
    attempts,
  );
}

/**
 * Asks the connection that started a job whether it has finished.
 *
 * Through the connection the job recorded, not through "this person's
 * generator": once more than one provider is connected that phrase stops
 * naming anything, and a job started on one and polled on another is a job
 * that never completes.
 *
 * The shape returned matches what `finishJob` already handled, so the calling
 * code did not have to learn a new vocabulary to stop knowing about vendors.
 */
export async function routePoll(
  admin: SupabaseClient,
  args: { connectionId: string; ref: string; statusUrl: string; capability?: Capability },
): Promise<{
  status: "queued" | "in_progress" | "completed" | "failed" | "nsfw";
  videoUrl: string | null;
  error: string | null;
  code?: string;
  mime?: string;
}> {
  let opened;
  try {
    opened = await openConnection(admin, args.connectionId);
  } catch (thrown) {
    // The connection was forgotten while a job was in flight, or its grant
    // is gone. Terminal, and said plainly rather than retried against nothing.
    const code = (thrown as { code?: string }).code ?? "connection_gone";
    return { status: "failed", videoUrl: null, error: code, code };
  }

  const adapter = adapterFor(opened.providerSlug, opened.authKind);

  const polled = await adapter.poll(
    { connectionId: args.connectionId, secret: opened.secret, endpoint: opened.endpoint },
    { ref: args.ref, statusUrl: args.statusUrl, state: "running", capability: args.capability },
  );

  if (polled.state === "queued") return { status: "queued", videoUrl: null, error: null };
  if (polled.state === "running") return { status: "in_progress", videoUrl: null, error: null };
  if (polled.state === "done") {
    return { status: "completed", videoUrl: polled.outputUrl ?? null, error: null, mime: polled.outputMime };
  }

  return {
    // `refused` is the shared word for what Higgsfield calls nsfw, and the
    // distinction matters downstream: retrying the same prompt fails the same
    // way and charges again for the privilege.
    status: polled.verdict?.code === "refused" ? "nsfw" : "failed",
    videoUrl: null,
    error: polled.verdict?.detail ?? null,
    code: polled.verdict?.code,
  };
}

/** An adapter's verdict, however the failure arrived. */
function verdictOf(thrown: unknown, slug: string, authKind: string): Verdict {
  const status = (thrown as { status?: number })?.status;
  const detail = thrown instanceof Error ? thrown.message : String(thrown);

  if (typeof status === "number") {
    try {
      return adapterFor(slug, authKind).classify(status, { detail });
    } catch {
      // No adapter is a bug in the registry, not a provider failure.
    }
  }

  // A `Refused` from the REST path already carries a code; anything else is
  // treated as this model's problem so the ladder moves on rather than stopping.
  const code = (thrown as { code?: string })?.code;
  return {
    code: (code as Verdict["code"]) ?? "no_models",
    retryable: (thrown as { retryable?: boolean })?.retryable ?? false,
    tryAnotherModel: code !== "no_credits" && code !== "bad_key",
    tryAnotherProvider: true,
    detail,
  };
}

function readable(capability: Capability): string {
  return capability.replace(/_generation$/, "").replace(/_/g, " ");
}
