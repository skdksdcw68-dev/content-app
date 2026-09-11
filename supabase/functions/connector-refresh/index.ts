/**
 * Asks a connection again what it can do.
 *
 * Needed for three ordinary reasons and one urgent one.
 *
 * Ordinary: a provider grants access to a new model and nobody should have to
 * reconnect to see it; a token was refreshed and the capability list should be
 * re-checked while we know it works; a capability lookup came back empty and
 * the honest first move is to ask again before telling somebody they cannot do
 * something.
 *
 * Urgent: the first real connection to Higgsfield stored its tokens correctly
 * and discovered nothing -- zero capabilities, zero models. `initialize`
 * clearly worked, because the account label came back from `serverInfo`, so
 * either `tools/list` returned names this build does not recognise or it
 * returned nothing at all. Discovery that fails silently at connect time is the
 * worst possible version of this feature, because the person is told they are
 * connected and the agent then finds an empty shelf.
 *
 * So this reports what it actually saw. `tools` in the response is the raw list
 * of names the server offered, whether or not any of them mapped -- which turns
 * "it did not work" into "it offers these, and we map none of them".
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { open } from "../_shared/crypto.ts";
import { McpSession, mcpAdapter } from "../_shared/connectors/mcp.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);

    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const body = await request.json().catch(() => ({})) as { connectionId?: string };

    // Read through the user's own view first, so a connection id that is not
    // theirs is simply not found rather than refused with a hint.
    const { data: mine } = await asUser
      .from("connections")
      .select("id")
      .eq("status", "active")
      .is("revoked_at", null)
      .order("connected_at", { ascending: false });

    const target = body.connectionId
      ? (mine ?? []).find((row: { id: string }) => row.id === body.connectionId)?.id
      : (mine ?? [])[0]?.id;

    if (!target) throw new PublicError("No connected provider to refresh.", 404);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: rows } = await admin.rpc("read_connection", { p_connection: target });
    const connection = (rows ?? [])[0];
    if (!connection?.access_ct) throw new PublicError("That connection has no credential.", 409);

    const token = await open(connection.access_ct, `${target}:access`);
    const endpoint = connection.mcp_url ?? connection.api_base;

    // The raw list, before any mapping, so a failure is legible rather than a
    // shrug. Deliberately outside the adapter: the adapter's job is to map, and
    // this is asking what it had to map from.
    let tools: string[] = [];
    try {
      const session = new McpSession(endpoint, token);
      await session.open();
      tools = (await session.tools()).map((tool) => tool.name);
    } catch (thrown) {
      console.error("tools/list", thrown);
    }

    let recorded = 0;
    let capabilities: string[] = [];

    try {
      const adapter = mcpAdapter(connection.provider_slug);
      const discovery = await adapter.discover({
        connectionId: target,
        secret: token,
        endpoint,
      });

      const { data: count } = await admin.rpc("record_discovery", {
        p_connection: target,
        p_models: discovery.models,
      });
      recorded = Number(count ?? 0);
      capabilities = [...new Set(discovery.models.map((m) => m.capability))];

      if (discovery.tools) {
        await admin.rpc("record_tools", { p_connection: target, p_tools: discovery.tools });
      }

      if (discovery.accountLabel) {
        await admin.rpc("activate_connection", {
          p_connection: target,
          p_label: discovery.accountLabel,
          p_external: discovery.externalAccountId,
        });
      }
    } catch (thrown) {
      console.error("discover", thrown);
      // A discovery that throws does not fault the connection: the
      // authorization is still good, and marking it broken would send somebody
      // to reconnect a thing that is connected.
      return json({
        connectionId: target,
        provider: connection.provider_slug,
        tools,
        recorded: 0,
        capabilities: [],
        error: thrown instanceof Error ? thrown.message : "discovery failed",
      });
    }

    return json({
      connectionId: target,
      provider: connection.provider_slug,
      tools,
      recorded,
      capabilities,
    });
  } catch (error) {
    return fail(error);
  }
});
