/**
 * Connecting a provider without anybody typing an API key.
 *
 * Everything here is discovered rather than pinned. A provider is allowed to
 * move its own endpoints, and an integration that hardcodes them breaks on a
 * morning nobody chose. So the chain is:
 *
 *   the MCP endpoint 401s and names its resource metadata
 *     -> the resource metadata names its authorization servers
 *       -> the authorization server metadata names authorize/token/register
 *         -> we register ourselves, once, and keep the client id
 *
 * Verified against Higgsfield on 9 Sep 2026: the registration endpoint issues a
 * client id with `token_endpoint_auth_method: none`, so it is a public client
 * and PKCE is what makes the exchange safe rather than a client secret.
 *
 * The redirect lands on OUR server, not the app. That is the whole reason the
 * token never reaches the client: the code is exchanged here, the result is
 * sealed here, and the app is told only that a connection exists.
 */

import { seal } from "../crypto.ts";

export interface ResourceMetadata {
  resource: string;
  authorization_servers: string[];
  scopes_supported?: string[];
}

export interface ServerMetadata {
  issuer: string;
  authorization_endpoint: string;
  token_endpoint: string;
  registration_endpoint?: string;
  code_challenge_methods_supported?: string[];
  scopes_supported?: string[];
}

/** Reads the protected-resource document an MCP endpoint advertises.
 *
 *  The 401 is asked for rather than avoided: `www-authenticate` carries the
 *  exact metadata URL, and guessing the well-known path is how a client works
 *  against one server and not the next. */
export async function discoverResource(mcpUrl: string): Promise<ResourceMetadata> {
  const probe = await fetch(mcpUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
  });

  const challenge = probe.headers.get("www-authenticate") ?? "";
  const named = challenge.match(/resource_metadata="([^"]+)"/)?.[1];

  const url = named ?? new URL("/.well-known/oauth-protected-resource", mcpUrl).toString();
  const response = await fetch(url);
  if (!response.ok) throw new Error(`resource metadata ${response.status} at ${url}`);
  return await response.json() as ResourceMetadata;
}

/** Reads an authorization server's own metadata, trying both well-known paths
 *  the specs disagree about. */
export async function discoverServer(issuer: string): Promise<ServerMetadata> {
  const candidates = [
    new URL("/.well-known/oauth-authorization-server", issuer).toString(),
    new URL("/.well-known/openid-configuration", issuer).toString(),
  ];

  for (const url of candidates) {
    const response = await fetch(url).catch(() => null);
    if (response?.ok) {
      const metadata = await response.json() as ServerMetadata;
      if (metadata.authorization_endpoint && metadata.token_endpoint) return metadata;
    }
  }
  throw new Error(`no authorization server metadata for ${issuer}`);
}

export interface Registration {
  client_id: string;
  client_secret?: string;
  registered: Record<string, unknown>;
}

/** Registers Autocast with a provider. Once per provider, not per user: DCR
 *  issues a client id for the application, and every person's authorization
 *  then runs against it. */
/**
 * How Autocast introduces itself on somebody else's consent screen.
 *
 * The first real authorization showed a grey letter avatar and
 * "dosszkllkassvyprkhrg.supabase.co" under a warning about trusting it. Every
 * word of that was accurate and the whole thing read like a phishing attempt --
 * which is the point at which a person quite reasonably taps Deny.
 *
 * These four fields are standard registration metadata and every OAuth consent
 * screen renders them. They cost nothing and they are the difference between
 * "Autocast, netrocast.com" and an unexplained subdomain.
 */
const BRANDING = {
  client_uri: "https://netrocast.com",
  logo_uri: "https://netrocast.com/logo.png",
  tos_uri: "https://netrocast.com/terms.html",
  policy_uri: "https://netrocast.com/privacy.html",
} as const;

/** Whether a stored registration predates the branding above, so it can be
 *  redone rather than left looking anonymous forever. */
export function needsRebranding(registered: Record<string, unknown> | null): boolean {
  return !registered || typeof registered.logo_uri !== "string";
}

export async function register(
  metadata: ServerMetadata,
  redirectUri: string,
  scope: string,
): Promise<Registration> {
  if (!metadata.registration_endpoint) {
    throw new Error("provider does not support dynamic registration");
  }

  const response = await fetch(metadata.registration_endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      client_name: "Autocast",
      redirect_uris: [redirectUri],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
      scope,
      ...BRANDING,
    }),
  });

  if (!response.ok) {
    throw new Error(`registration ${response.status}: ${(await response.text()).slice(0, 200)}`);
  }

  const registered = await response.json() as Record<string, unknown>;
  const clientId = registered.client_id;
  if (typeof clientId !== "string") throw new Error("registration returned no client_id");

  return {
    client_id: clientId,
    client_secret: typeof registered.client_secret === "string" ? registered.client_secret : undefined,
    registered,
  };
}

/** PKCE. Required here rather than optional: the client is public, so the
 *  verifier is the only thing stopping a stolen code being redeemed. */
export async function pkce(): Promise<{ verifier: string; challenge: string }> {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const verifier = base64url(bytes);

  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: base64url(new Uint8Array(digest)) };
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function authorizeUrl(
  metadata: ServerMetadata,
  args: { clientId: string; redirectUri: string; state: string; challenge: string; scope: string; resource?: string },
): string {
  const url = new URL(metadata.authorization_endpoint);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", args.clientId);
  url.searchParams.set("redirect_uri", args.redirectUri);
  url.searchParams.set("state", args.state);
  url.searchParams.set("code_challenge", args.challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("scope", args.scope);
  // Binds the token to the MCP endpoint it is for, so a token minted for one
  // resource cannot be replayed against another.
  if (args.resource) url.searchParams.set("resource", args.resource);
  return url.toString();
}

export interface Tokens {
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
  scope?: string;
}

export async function exchange(
  metadata: ServerMetadata,
  args: { code: string; clientId: string; clientSecret?: string; redirectUri: string; verifier: string; resource?: string },
): Promise<Tokens> {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code: args.code,
    client_id: args.clientId,
    redirect_uri: args.redirectUri,
    code_verifier: args.verifier,
  });
  if (args.clientSecret) body.set("client_secret", args.clientSecret);
  if (args.resource) body.set("resource", args.resource);

  const response = await fetch(metadata.token_endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });

  if (!response.ok) {
    throw new Error(`token exchange ${response.status}: ${(await response.text()).slice(0, 200)}`);
  }
  return await response.json() as Tokens;
}

/** Seals the tokens against the connection they belong to.
 *
 *  Same AAD discipline as platform tokens in 0002: ciphertext moved into
 *  another connection's row fails to decrypt, so SQL write access is not enough
 *  to spend somebody else's credits. */
export async function sealTokens(connectionId: string, tokens: Tokens): Promise<{
  access_ct: string;
  refresh_ct: string | null;
  access_expires_at: string | null;
  scope: string;
}> {
  return {
    access_ct: await seal(tokens.access_token, `${connectionId}:access`),
    refresh_ct: tokens.refresh_token
      ? await seal(tokens.refresh_token, `${connectionId}:refresh`)
      : null,
    access_expires_at: tokens.expires_in
      ? new Date(Date.now() + tokens.expires_in * 1000).toISOString()
      : null,
    scope: tokens.scope ?? "",
  };
}
