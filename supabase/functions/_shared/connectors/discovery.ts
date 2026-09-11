/**
 * Asking a connection what it can do, and writing the answer down.
 *
 * One place, because three callers need it -- connecting, the "check what it
 * offers" button, and chat finding nothing -- and the first time it failed, it
 * failed in the gap between them: Abel's first real sign-in returned 101 tools,
 * `record_discovery` rejected the model list (one audio model listed under both
 * audio and voice), the callback never looked at the error, and the account
 * showed "connected, nothing available" with no record of why.
 *
 * So the write is checked here, every time, and a failure is an exception with
 * the database's own words in it.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import type { Discovery } from "./contract.ts";
import { adapterFor } from "./registry.ts";
import { openConnection } from "./tokens.ts";

export interface Rediscovered {
  recorded: number;
  capabilities: string[];
  tools: number;
  accountLabel: string;
}

/** Writes a discovery. Throws when the database refuses it. */
export async function storeDiscovery(
  admin: SupabaseClient,
  connectionId: string,
  discovery: Discovery,
): Promise<number> {
  const { data, error } = await admin.rpc("record_discovery", {
    p_connection: connectionId,
    p_models: discovery.models,
  });
  if (error) throw new Error(`record_discovery: ${error.message}`);

  // The raw list too, mapped or not -- so "why did this connect with nothing"
  // has an answer in the database. Its failure is logged, not thrown: the
  // models are what the agent routes on, the tool list is for diagnosis.
  if (discovery.tools) {
    const { error: toolsError } = await admin.rpc("record_tools", {
      p_connection: connectionId,
      p_tools: discovery.tools,
    });
    if (toolsError) console.error("record_tools", toolsError.message);
  }
  return Number(data ?? 0);
}

/** Opens a connection (refreshing its token if due), discovers, stores. */
export async function rediscover(admin: SupabaseClient, connectionId: string): Promise<Rediscovered> {
  const opened = await openConnection(admin, connectionId);
  const adapter = adapterFor(opened.providerSlug, opened.authKind);

  const discovery = await adapter.discover({
    connectionId,
    secret: opened.secret,
    endpoint: opened.endpoint,
  });
  const recorded = await storeDiscovery(admin, connectionId, discovery);

  return {
    recorded,
    capabilities: [...new Set(discovery.models.map((m) => m.capability))],
    tools: discovery.tools?.length ?? 0,
    accountLabel: discovery.accountLabel,
  };
}
