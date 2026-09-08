/**
 * Small helpers shared by every function. Deliberately thin -- an Edge Function
 * is a front door, and a front door with a framework in it is a liability.
 */

export const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

export function preflight(): Response {
  return new Response(null, { status: 204, headers: CORS });
}

/**
 * An error the caller is allowed to see. Anything thrown that is not one of
 * these is logged and reported as a bare 500, because the difference between
 * "your brand id is wrong" and "the token store is unreachable" is not
 * something a client should be able to probe for.
 */
export class PublicError extends Error {
  constructor(
    message: string,
    readonly status = 400,
    /** Set when the cause is a bad minute rather than a bad request, so a
     *  caller running unattended can leave the work in the queue instead of
     *  marking it dead. Nothing is retried on the strength of a 4xx. */
    readonly retryable = false,
    /** Set when the cause was classified at the point of failure. Travels to
     *  whoever records the outcome, so the customer-facing wording is chosen
     *  from a code rather than reconstructed from this message. */
    readonly failureCode: string | null = null,
  ) {
    super(message);
  }
}

export function fail(error: unknown): Response {
  if (error instanceof PublicError) {
    return json({ error: error.message }, error.status);
  }
  console.error("unhandled", error instanceof Error ? error.stack ?? error.message : error);
  return json({ error: "Something went wrong on our side." }, 500);
}

/** Sends the browser onward, used at the end of an OAuth round trip. */
export function redirect(location: string): Response {
  return new Response(null, { status: 302, headers: { Location: location } });
}
