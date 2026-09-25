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

/** What one unauthenticated request to the MCP endpoint says about it. */
export interface Probe {
  /** 2xx without a token: the server is open and there is nothing to sign
   *  in to. Anything else and OAuth is the way in. */
  open: boolean;
  status: number;
  /** The metadata URL named in `WWW-Authenticate`, when the server names one
   *  (RFC 9728 §5.1). The spec's own way; guessed paths are the fallback. */
  resourceMetadataUrl: string | null;
}

/** Asks the MCP endpoint, without a token, what protects it.
 *
 *  `Accept` carries both types because a streamable-HTTP server refuses a
 *  request without `text/event-stream` (406) before it ever gets to
 *  authorization, and a 406 has no `WWW-Authenticate` on it. */
export async function probeResource(mcpUrl: string): Promise<Probe> {
  const response = await fetch(mcpUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      "MCP-Protocol-Version": "2025-06-18",
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "Autocast", version: "1" } },
    }),
  });
  // Read and drop, so the connection is released.
  await response.text().catch(() => "");
  const challenge = response.headers.get("www-authenticate") ?? "";
  return {
    open: response.ok,
    status: response.status,
    resourceMetadataUrl: challenge.match(/resource_metadata="([^"]+)"/)?.[1] ?? null,
  };
}

/** The well-known URLs RFC 9728 allows for a resource with a path: the
 *  path-aware form first (`/.well-known/oauth-protected-resource/mcp` for a
 *  server at `/mcp`), then the origin's. */
function resourceMetadataCandidates(mcpUrl: string, named: string | null): string[] {
  const url = new URL(mcpUrl);
  const path = url.pathname.replace(/\/+$/, "");
  const out: string[] = [];
  if (named) out.push(named);
  if (path && path !== "/") out.push(`${url.origin}/.well-known/oauth-protected-resource${path}`);
  out.push(`${url.origin}/.well-known/oauth-protected-resource`);
  return [...new Set(out)];
}

/** Reads the protected-resource document an MCP endpoint advertises.
 *
 *  The 401 is asked for rather than avoided: `www-authenticate` carries the
 *  exact metadata URL, and guessing the well-known path is how a client works
 *  against one server and not the next. The guesses come after it. */
export async function discoverResource(mcpUrl: string, probe?: Probe): Promise<ResourceMetadata> {
  const named = probe ? probe.resourceMetadataUrl : (await probeResource(mcpUrl)).resourceMetadataUrl;
  let last = "";
  for (const url of resourceMetadataCandidates(mcpUrl, named)) {
    const response = await fetch(url, { headers: { Accept: "application/json" } }).catch(() => null);
    if (!response?.ok) {
      last = `${response?.status ?? "unreachable"} at ${url}`;
      continue;
    }
    const metadata = await response.json().catch(() => null) as ResourceMetadata | null;
    if (metadata && Array.isArray(metadata.authorization_servers) && metadata.authorization_servers.length > 0) {
      return metadata;
    }
    last = `no authorization_servers at ${url}`;
  }
  throw new Error(`resource metadata: ${last}`);
}

/** Every well-known URL RFC 8414 and OpenID Discovery allow for an issuer,
 *  path-aware forms included (`/.well-known/oauth-authorization-server/tenant`
 *  for an issuer at `/tenant`), in the order the specs say to try them. */
function serverMetadataCandidates(issuer: string): string[] {
  const url = new URL(issuer);
  const path = url.pathname.replace(/\/+$/, "");
  const out: string[] = [];
  if (path && path !== "/") {
    out.push(`${url.origin}/.well-known/oauth-authorization-server${path}`);
    out.push(`${url.origin}/.well-known/openid-configuration${path}`);
    out.push(`${url.origin}${path}/.well-known/openid-configuration`);
  }
  out.push(`${url.origin}/.well-known/oauth-authorization-server`);
  out.push(`${url.origin}/.well-known/openid-configuration`);
  return [...new Set(out)];
}

/** Reads an authorization server's own metadata. */
export async function discoverServer(issuer: string): Promise<ServerMetadata> {
  for (const url of serverMetadataCandidates(issuer)) {
    const response = await fetch(url, { headers: { Accept: "application/json" } }).catch(() => null);
    if (response?.ok) {
      const metadata = await response.json().catch(() => null) as ServerMetadata | null;
      if (metadata?.authorization_endpoint && metadata.token_endpoint) return metadata;
    }
  }
  throw new Error(`no authorization server metadata for ${issuer}`);
}

/** Everything needed to sign in to one MCP endpoint, found in one go. */
export interface AuthorizationDiscovery {
  resource: ResourceMetadata;
  server: ServerMetadata;
}

/**
 * Which authorization server to use for an MCP endpoint, and its metadata.
 *
 * The resource document may name several servers (RFC 9728 leaves the pick
 * to the client), and an endpoint may also publish metadata at its own
 * origin. The order here is the one that has worked: the endpoint's own
 * origin first when it can register clients -- Higgsfield's proxies straight
 * to its real server with the right hints -- then each named server in turn.
 * A server with no registration endpoint is skipped when another has one,
 * because without registration there is no client id and no way in.
 *
 * The same rule runs at sign-in, at the code exchange and at every refresh,
 * so all three land on the one server that issued the client id. A second
 * rule for later steps would be a way to exchange a code with the wrong
 * server.
 */
export async function discoverAuthorization(
  mcpUrl: string,
  probe?: Probe,
): Promise<AuthorizationDiscovery> {
  const resource = await discoverResource(mcpUrl, probe);

  // 🔴 The resource's OWN list comes first. RFC 9728 makes
  // `authorization_servers` the authoritative answer to "who authorizes this
  // resource"; the MCP origin is a guess for servers that publish no metadata
  // at all, and it belongs last.
  //
  // This was the other way round, and it cost the product its generator.
  // Higgsfield's protected-resource metadata names
  // `https://clerk.higgsfield.ai`, and says in as many words that a client
  // which can receive a redirect should use it. But `mcp.higgsfield.ai` also
  // answers /.well-known/oauth-authorization-server WITH a registration
  // endpoint, so putting the origin first meant we registered and authorized
  // there every time and never looked at what the resource actually said. The
  // browser opened, and never came back: connections sat at `pending` for
  // weeks (Abel, 25 Sep 2026, and twice before).
  const issuers = [...resource.authorization_servers, new URL(mcpUrl).origin];
  let fallback: ServerMetadata | null = null;
  const failures: string[] = [];

  for (const issuer of [...new Set(issuers)]) {
    let server: ServerMetadata;
    try {
      server = await discoverServer(issuer);
    } catch (thrown) {
      failures.push(thrown instanceof Error ? thrown.message : String(thrown));
      continue;
    }
    if (server.registration_endpoint) return { resource, server };
    fallback ??= server;
  }

  if (fallback) return { resource, server: fallback };
  throw new Error(`no usable authorization server: ${failures.join("; ")}`);
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

/** Trades a refresh token for a new access token.
 *
 *  Higgsfield's access tokens last a day. Without this every signed-in
 *  connection would fail the morning after it was made, and the person would be
 *  asked to sign in again for no reason they could see. */
export async function refreshTokens(
  metadata: ServerMetadata,
  args: { refreshToken: string; clientId: string; clientSecret?: string; resource?: string },
): Promise<Tokens> {
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: args.refreshToken,
    client_id: args.clientId,
  });
  if (args.clientSecret) body.set("client_secret", args.clientSecret);
  if (args.resource) body.set("resource", args.resource);

  const response = await fetch(metadata.token_endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });

  if (!response.ok) {
    // Carries the status so the caller can tell a revoked grant (400/401,
    // reconnect) from the auth server having a bad minute (5xx, retry).
    const error = new Error(`token refresh ${response.status}`) as Error & { status: number };
    error.status = response.status;
    throw error;
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
