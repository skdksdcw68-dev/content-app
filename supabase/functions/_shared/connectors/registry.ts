/**
 * Which adapter handles which provider, and nothing else.
 *
 * This is the whole of the coupling. Everything above it names a capability and
 * a connection; everything below it names a vendor. Adding a provider is a file
 * and one line here -- not a change to the agent, the worker, the chat, or the
 * generation pipeline.
 *
 * There is deliberately no fallback adapter. A connection whose provider has no
 * adapter is a bug in this file, and returning something that pretends to work
 * would turn it into a silent one.
 */

import type { Adapter } from "./contract.ts";
import { higgsfieldRest } from "./higgsfield-rest.ts";
import { mcpAdapter } from "./mcp.ts";

/**
 * Keyed by `providers.slug` and `connections.auth_kind` together.
 *
 * Both, because one provider can be reachable two ways: Higgsfield over MCP
 * with an account, and Higgsfield over REST with a pasted key. Same vendor,
 * different door, genuinely different code -- and a person who pasted a key
 * before OAuth existed should keep working without being migrated.
 */
const ADAPTERS: Record<string, Adapter> = {
  "higgsfield:api_key": higgsfieldRest,
  // Signing in is now the default way to connect Higgsfield, and it was
  // missing from here: a signed-in account could be discovered but not asked
  // to make anything, because the ladder found no adapter for its door.
  "higgsfield:mcp_oauth": mcpAdapter("higgsfield"),
};

export function adapterFor(providerSlug: string, authKind: string): Adapter {
  const adapter = ADAPTERS[`${providerSlug}:${authKind}`];
  if (!adapter) {
    throw new Error(`no adapter for ${providerSlug} over ${authKind}`);
  }
  return adapter;
}

/** What this build can actually talk to. Used by the connect list so a provider
 *  row nobody implemented is never offered to somebody. */
export function implementedProviders(): Array<{ slug: string; authKind: string }> {
  return Object.keys(ADAPTERS).map((key) => {
    const [slug, authKind] = key.split(":");
    return { slug, authKind };
  });
}
