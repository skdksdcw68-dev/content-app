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
  discoverResource,
  discoverServer,
  needsRebranding,
  pkce,
  register,
} from "../_shared/connectors/oauth.ts";

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

    const { data: providers } = await admin
      .from("providers")
      .select("id, slug, name, auth_kind, mcp_url")
      .eq("slug", slug)
      .eq("enabled", true)
      .limit(1);

    const provider = (providers ?? [])[0];
    if (!provider) throw new PublicError("That provider is not available.", 404);
    if (provider.auth_kind !== "mcp_oauth") {
      throw new PublicError("That provider is connected a different way.", 400);
    }
    if (!provider.mcp_url) throw new PublicError("That provider has no endpoint configured.", 500);

    const redirectUri = `${PUBLIC_FUNCTIONS}/connector-callback`;

    // What protects the endpoint, and who can authorize for it.
    const resource = await discoverResource(provider.mcp_url);
    const issuer = resource.authorization_servers?.[0];
    if (!issuer) throw new PublicError("That provider did not say how to sign in.", 502);

    const scope = (resource.scopes_supported ?? ["openid", "email", "offline_access"]).join(" ");

    // The MCP endpoint itself is an authorization server here, and the one that
    // supports dynamic registration. Its metadata is preferred; the issuer it
    // named is the fallback for a provider that separates them.
    let server = await discoverServer(provider.mcp_url).catch(() => null);
    if (!server?.registration_endpoint) {
      server = await discoverServer(issuer);
    }

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

    if (!client || client.redirect_uri !== redirectUri || needsRebranding(stored?.registered ?? null)) {
      const registration = await register(server, redirectUri, scope);
      await admin.rpc("upsert_provider_client", {
        p_slug: slug,
        p_client_id: registration.client_id,
        p_secret_ct: registration.client_secret
          ? await seal(registration.client_secret, `${slug}:client`)
          : null,
        p_redirect: redirectUri,
        p_registered: registration.registered,
      });
      client = { client_id: registration.client_id, redirect_uri: redirectUri };
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

    return json({
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
