/**
 * Begins connecting a provider. Returns a URL for the app to open.
 *
 * The app's whole part in this is opening that URL in an
 * `ASWebAuthenticationSession` and waiting -- the same thing it already does
 * for TikTok. It never sees a client id, a verifier, a code or a token.
 *
 * Everything about the provider is discovered at this moment rather than
 * configured: the MCP endpoint is asked what protects it, that answer names an
 * authorization server, and that server's metadata names the endpoints. A
 * provider is allowed to move its own doors, and an integration that pinned
 * them would break on a morning nobody chose.
 *
 * Registration happens once per provider and is cached in `provider_clients`.
 * Re-registering per person would create a record on their side per install,
 * which is both rude and a way to hit a limit nobody documented.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { seal } from "../_shared/crypto.ts";
import {
  authorizeUrl,
  discoverAuthorization,
  needsRebranding,
  pkce,
  probeResource,
  register,
} from "../_shared/connectors/oauth.ts";
import { mcpAdapter } from "../_shared/connectors/mcp.ts";
import { storeDiscovery } from "../_shared/connectors/discovery.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PUBLIC_FUNCTIONS = Deno.env.get("PUBLIC_FUNCTIONS_URL") ?? `${SUPABASE_URL}/functions/v1`;

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

    const body = await request.json().catch(() => ({})) as { provider?: string; scheme?: string };
    const slug = (body.provider ?? "").trim();
    if (!slug) throw new PublicError("Say which provider.");

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    // Catalogue rows belong to everyone; a server somebody added themselves
    // (0055) is theirs alone, and nobody else can start a sign-in to it.
    const { data: providers } = await admin
      .from("providers")
      .select("id, slug, name, auth_kind, mcp_url, owner_id")
      .eq("slug", slug)
      .eq("enabled", true)
      .or(`owner_id.is.null,owner_id.eq.${auth.user.id}`)
      .limit(1);

    const provider = (providers ?? [])[0];
    if (!provider) throw new PublicError("That provider is not available.", 404);
    if (provider.auth_kind !== "mcp_oauth") {
      throw new PublicError("That provider is connected a different way.", 400);
    }
    if (!provider.mcp_url) throw new PublicError("That provider has no endpoint configured.", 500);

    const redirectUri = `${PUBLIC_FUNCTIONS}/connector-callback`;

    // One request without a token says which kind of server this is.
    const probe = await probeResource(provider.mcp_url).catch((thrown) => {
      console.error("connector-start probe", slug, thrown);
      throw new PublicError("That server could not be reached. Check the address.", 502);
    });

    // An open server: it answered without a token, so there is no sign-in
    // to do. It is connected on the spot and asked what it can make, and
    // the app is told there is no page to open.
    if (probe.open) {
      const { data: connectionId, error: beginError } = await admin.rpc("begin_connection", {
        p_user: auth.user.id,
        p_provider_slug: slug,
      });
      if (beginError) throw beginError;

      // A credential row with nothing in it, so the connection reads like
      // every other one; the MCP session sends no header for an empty token.
      await admin.rpc("store_connection_secret", {
        p_connection: connectionId,
        p_access_ct: await seal("", `${connectionId}:access`),
        p_refresh_ct: null,
        p_expires: null,
        p_scope: "",
      });

      let label = provider.name;
      try {
        const discovery = await mcpAdapter(slug).discover({
          connectionId,
          secret: "",
          endpoint: provider.mcp_url,
        });
        label = discovery.accountLabel || label;
        await storeDiscovery(admin, connectionId, discovery);
      } catch (thrown) {
        console.error("connector-start open-server discovery", slug, thrown);
      }

      await admin.rpc("activate_connection", {
        p_connection: connectionId,
        p_label: label,
        p_external: null,
      });

      console.log("connector-start", slug, "open server, connected", connectionId);
      return json({ url: null, connected: true, provider: provider.name, connectionId });
    }

    // What protects the endpoint, and who can authorize for it.
    let found;
    try {
      found = await discoverAuthorization(provider.mcp_url, probe);
    } catch (thrown) {
      console.error("connector-start discovery", slug, thrown);
      throw new PublicError(
        `That server answered ${probe.status} but did not say how to sign in to it. It may need an API key instead of a sign-in.`,
        502,
      );
    }
    const { resource, server } = found;
    if (!server.registration_endpoint) {
      throw new PublicError("That server does not let apps register themselves, so Autocast cannot sign in to it.", 502);
    }

    const scope = (resource.scopes_supported ?? ["openid", "email", "offline_access"]).join(" ");

    // Registered once, then reused.
    const { data: known } = await admin.rpc("read_provider_client", { p_slug: slug });
    let client = (known ?? [])[0] as { client_id: string; redirect_uri: string } | undefined;

    // A registration made before the branding existed is redone once, so the
    // consent screen stops showing a grey letter and a raw subdomain. Cheap:
    // DCR is idempotent from our side and the new client id simply replaces the
    // old one for future authorizations.
    const { data: stored } = await admin
      .from("provider_clients")
      .select("registered")
      .eq("provider_id", provider.id)
      .maybeSingle();

    // A client id belongs to the server that issued it. If discovery now picks
    // a different authorization server -- because the resource's metadata
    // changed, or because we used to pick the wrong one -- the cached id is
    // meaningless there and authorizing with it fails on the provider's own
    // page, where we never see the error and the person never comes back.
    // Recorded alongside the registration so a change re-registers by itself.
    const issuer = (server as { issuer?: string }).issuer ?? "";
    const registeredAt = (stored?.registered as { _issuer?: unknown } | null)?._issuer;
    const movedServer = issuer !== "" && registeredAt !== issuer;

    if (!client || client.redirect_uri !== redirectUri || movedServer || needsRebranding(stored?.registered ?? null)) {
      const registration = await register(server, redirectUri, scope);
      await admin.rpc("upsert_provider_client", {
        p_slug: slug,
        p_client_id: registration.client_id,
        p_secret_ct: registration.client_secret
          ? await seal(registration.client_secret, `${slug}:client`)
          : null,
        p_redirect: redirectUri,
        p_registered: { ...registration.registered, _issuer: issuer },
      });
      client = { client_id: registration.client_id, redirect_uri: redirectUri };
      console.log("connector-start", slug, "registered at", issuer);
    }

    const { data: connectionId, error: beginError } = await admin.rpc("begin_connection", {
      p_user: auth.user.id,
      p_provider_slug: slug,
    });
    if (beginError) throw beginError;

    const { verifier, challenge } = await pkce();
    // Unguessable, and the only thing tying the redirect back to this attempt.
    const state = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "");

    await admin.rpc("stash_authorization", {
      p_state: state,
      p_connection: connectionId,
      p_provider: provider.id,
      p_verifier: verifier,
      p_scheme: body.scheme ?? "",
    });

    console.log("connector-start", slug, "authorize at", server.authorization_endpoint);
    return json({
      connected: false,
      url: authorizeUrl(server, {
        clientId: client.client_id,
        redirectUri,
        state,
        challenge,
        scope,
        resource: resource.resource,
      }),
      // So the app can show "Connecting Higgsfield" rather than a slug.
      provider: provider.name,
      connectionId,
    });
  } catch (error) {
    return fail(error);
  }
});
