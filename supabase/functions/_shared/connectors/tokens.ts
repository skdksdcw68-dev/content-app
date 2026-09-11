/**
 * The credential for a connection, opened -- and refreshed first if it is about
 * to stop working.
 *
 * One function, because every caller wants the same thing: a secret that will
 * work for the next call. Before this existed, a signed-in connection worked for
 * exactly as long as its first access token did, which for Higgsfield is a day.
 *
 * The opened secret is returned to the caller and goes nowhere else. It is never
 * logged, never stored in the clear, and never placed in anything a model reads.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { open } from "../crypto.ts";
import { discoverResource, discoverServer, refreshTokens, sealTokens } from "./oauth.ts";

/** Refreshed when it has less than this left, so a token cannot expire between
 *  being read and being used on a slow provider call. */
const MARGIN_MS = 5 * 60_000;

export interface OpenedConnection {
  secret: string;
  authKind: string;
  providerSlug: string;
  endpoint: string;
}

export class NeedsReconnect extends Error {
  readonly code = "needs_reconnect";
  constructor() {
    super("the connection needs signing in again");
    this.name = "NeedsReconnect";
  }
}

export async function openConnection(admin: SupabaseClient, connectionId: string): Promise<OpenedConnection> {
  const { data } = await admin.rpc("read_connection", { p_connection: connectionId });
  const connection = (data ?? [])[0];
  if (!connection?.access_ct) throw new Error("connection has no credential");

  const authKind = connection.auth_kind as string;
  const endpoint = authKind === "api_key"
    ? (connection.api_base ?? "")
    : (connection.mcp_url ?? connection.api_base ?? "");

  // The AAD differs by door: an OAuth token was sealed against
  // `${id}:access`, a pasted key pair against `${id}:provider` in 0012. Getting
  // this wrong fails to decrypt rather than decrypting something wrong, which
  // is the whole reason the binding exists.
  if (authKind === "api_key") {
    return {
      secret: await open(connection.access_ct, `${connectionId}:provider`),
      authKind,
      providerSlug: connection.provider_slug,
      endpoint,
    };
  }

  const expires = connection.access_expires_at ? Date.parse(connection.access_expires_at) : null;
  const stale = expires !== null && expires - Date.now() < MARGIN_MS;

  if (!stale) {
    return {
      secret: await open(connection.access_ct, `${connectionId}:access`),
      authKind,
      providerSlug: connection.provider_slug,
      endpoint,
    };
  }

  if (!connection.refresh_ct) {
    await markExpired(admin, connectionId);
    throw new NeedsReconnect();
  }

  const refreshToken = await open(connection.refresh_ct, `${connectionId}:refresh`);

  const resource = await discoverResource(endpoint);
  let server = await discoverServer(endpoint).catch(() => null);
  if (!server) server = await discoverServer(resource.authorization_servers[0]);

  const { data: known } = await admin.rpc("read_provider_client", { p_slug: connection.provider_slug });
  const client = (known ?? [])[0] as { client_id: string; client_secret_ct: string | null } | undefined;
  if (!client) throw new Error("no registration for this provider");

  let tokens;
  try {
    tokens = await refreshTokens(server, {
      refreshToken,
      clientId: client.client_id,
      clientSecret: client.client_secret_ct
        ? await open(client.client_secret_ct, `${connection.provider_slug}:client`)
        : undefined,
      resource: resource.resource,
    });
  } catch (thrown) {
    const status = (thrown as { status?: number }).status ?? 0;
    // A refused refresh means the grant is gone -- signed out, revoked, or
    // replaced. Only the person can fix that, so it is said once, where they
    // will see it, rather than retried every minute.
    if (status === 400 || status === 401) {
      await markExpired(admin, connectionId);
      throw new NeedsReconnect();
    }
    throw thrown;
  }

  // Some servers rotate the refresh token on use and some do not. Keeping the
  // old one when no new one came back is what keeps the second kind working.
  const sealed = await sealTokens(connectionId, {
    ...tokens,
    refresh_token: tokens.refresh_token ?? refreshToken,
  });
  await admin.rpc("store_connection_secret", {
    p_connection: connectionId,
    p_access_ct: sealed.access_ct,
    p_refresh_ct: sealed.refresh_ct,
    p_expires: sealed.access_expires_at,
    p_scope: sealed.scope,
  });

  return { secret: tokens.access_token, authKind, providerSlug: connection.provider_slug, endpoint };
}

async function markExpired(admin: SupabaseClient, connectionId: string): Promise<void> {
  await admin.rpc("fault_connection", {
    p_connection: connectionId,
    p_code: "needs_reconnect",
    p_status: "expired",
  });
}
