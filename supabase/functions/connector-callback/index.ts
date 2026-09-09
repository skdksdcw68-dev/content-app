/**
 * Where the provider sends the person back, and where the token stops.
 *
 * The redirect lands here rather than in the app, and that single choice is
 * what keeps the credential server-side: the code is exchanged here, the tokens
 * are sealed here, and the app is told only that a connection now exists.
 * Nothing in the response, and nothing the client can subsequently read,
 * contains a secret.
 *
 * Public by necessity -- a provider redirecting a browser carries no Supabase
 * session. What stands in for a JWT is the `state` parameter: it was minted in
 * `connector-start`, stashed server-side against the pending connection, and is
 * consumed here exactly once. A callback carrying a state nobody stashed is
 * discarded without touching anything.
 *
 * Discovery runs immediately afterwards, before the person is sent back, so
 * they return to a connection that already knows what it can do rather than to
 * a spinner and a later surprise.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { open } from "../_shared/crypto.ts";
import { discoverResource, discoverServer, exchange, sealTokens } from "../_shared/connectors/oauth.ts";
import { mcpAdapter } from "../_shared/connectors/mcp.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PUBLIC_FUNCTIONS = Deno.env.get("PUBLIC_FUNCTIONS_URL") ?? `${SUPABASE_URL}/functions/v1`;

/** A page rather than a redirect when there is no scheme to return to, so the
 *  person sees something rather than a blank tab. `ASWebAuthenticationSession`
 *  closes itself on the scheme, so the happy path rarely renders this. */
function page(title: string, detail: string, ok: boolean): Response {
  return new Response(
    `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
 body{font:-apple-system-body,system-ui,sans-serif;margin:0;min-height:100vh;
      display:grid;place-items:center;background:#fff;color:#111;padding:24px}
 @media (prefers-color-scheme:dark){body{background:#000;color:#fff}}
 .c{text-align:center;max-width:22rem}
 .m{font-size:44px;line-height:1;margin-bottom:14px}
 h1{font-size:1.15rem;margin:0 0 6px} p{margin:0;opacity:.6;font-size:.9rem}
</style>
<div class="c"><div class="m">${ok ? "&#10003;" : "&#9888;"}</div>
<h1>${title}</h1><p>${detail}</p></div>`,
    { status: ok ? 200 : 400, headers: { "Content-Type": "text/html; charset=utf-8" } },
  );
}

Deno.serve(async (request) => {
  const url = new URL(request.url);
  const state = url.searchParams.get("state") ?? "";
  const code = url.searchParams.get("code") ?? "";
  const denied = url.searchParams.get("error");

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);

  // Consumed once. A replay finds nothing, which is the point.
  const { data: claimed } = await admin.rpc("claim_authorization", { p_state: state });
  const attempt = (claimed ?? [])[0] as
    | { connection_id: string; provider_id: string; verifier: string; return_scheme: string }
    | undefined;

  if (!attempt) {
    return page("That link has expired", "Start the connection again from Autocast.", false);
  }

  const back = (ok: boolean, reason?: string) => {
    if (!attempt.return_scheme) {
      return ok
        ? page("Connected", "You can close this and go back to Autocast.", true)
        : page("Could not connect", reason ?? "Please try again.", false);
    }
    const target = new URL(`${attempt.return_scheme}://connector`);
    target.searchParams.set("status", ok ? "connected" : "failed");
    if (reason) target.searchParams.set("reason", reason);
    return Response.redirect(target.toString(), 302);
  };

  // The person said no. Not an error -- the connection is simply dropped.
  if (denied || !code) {
    await admin.rpc("fault_connection", {
      p_connection: attempt.connection_id,
      p_code: "needs_reconnect",
      p_status: "revoked",
    });
    return back(false, denied ?? "cancelled");
  }

  try {
    const { data: providers } = await admin
      .from("providers")
      .select("slug, mcp_url")
      .eq("id", attempt.provider_id)
      .limit(1);
    const provider = (providers ?? [])[0];
    if (!provider?.mcp_url) throw new Error("provider has no endpoint");

    const resource = await discoverResource(provider.mcp_url);
    let server = await discoverServer(provider.mcp_url).catch(() => null);
    if (!server) server = await discoverServer(resource.authorization_servers[0]);

    const { data: known } = await admin.rpc("read_provider_client", { p_slug: provider.slug });
    const client = (known ?? [])[0] as
      | { client_id: string; client_secret_ct: string | null; redirect_uri: string }
      | undefined;
    if (!client) throw new Error("no registration for this provider");

    const tokens = await exchange(server, {
      code,
      clientId: client.client_id,
      clientSecret: client.client_secret_ct
        ? await open(client.client_secret_ct, `${provider.slug}:client`)
        : undefined,
      redirectUri: `${PUBLIC_FUNCTIONS}/connector-callback`,
      verifier: attempt.verifier,
      resource: resource.resource,
    });

    const sealed = await sealTokens(attempt.connection_id, tokens);
    await admin.rpc("store_connection_secret", {
      p_connection: attempt.connection_id,
      p_access_ct: sealed.access_ct,
      p_refresh_ct: sealed.refresh_ct,
      p_expires: sealed.access_expires_at,
      p_scope: sealed.scope,
    });

    // Asked what it can do before the person is told they are connected. A
    // connection that is "active" with no capabilities is one the agent will
    // look at, find nothing in, and be unable to explain.
    let label = provider.slug;
    try {
      const adapter = mcpAdapter(provider.slug);
      const discovery = await adapter.discover({
        connectionId: attempt.connection_id,
        secret: tokens.access_token,
        endpoint: provider.mcp_url,
      });
      label = discovery.accountLabel || label;
      await admin.rpc("record_discovery", {
        p_connection: attempt.connection_id,
        p_models: discovery.models,
      });
    } catch (thrown) {
      // The authorization is real even if discovery stumbled, and throwing it
      // away would make the person log in again for nothing. Connected with no
      // capabilities is a visible, recoverable state -- see `fault_connection`
      // and the retry on next use.
      console.error("discovery after connect", thrown);
    }

    await admin.rpc("activate_connection", {
      p_connection: attempt.connection_id,
      p_label: label,
      p_external: null,
    });

    return back(true);
  } catch (thrown) {
    console.error("connector-callback", thrown);
    await admin.rpc("fault_connection", {
      p_connection: attempt.connection_id,
      p_code: "needs_reconnect",
      p_status: "error",
    });
    return back(false, "exchange_failed");
  }
});
