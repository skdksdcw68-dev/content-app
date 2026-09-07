/**
 * The generation adapter, in the shape every future one has to fit.
 *
 * Two functions and no state: `submit` starts work and returns where to look,
 * `poll` says whether it is done. Everything provider-specific -- the auth
 * header, the endpoint path, where the output URL sits in the response -- is in
 * this file and nowhere else. A second provider is a second file, not a change
 * to the queue.
 *
 * Three facts about Higgsfield shape the design, and all three are documented
 * rather than discovered later:
 *
 *   1. Requests are asynchronous. Submit returns immediately with a status_url.
 *      Nothing here ever blocks on generation, which takes minutes.
 *   2. Webhooks are UNSIGNED. The callback is treated as a wake-up and never as
 *      truth -- on receipt we re-GET status_url with our own key and believe
 *      that. The callback URL carries an unguessable per-job token so it cannot
 *      be found by scanning, but that is defence in depth, not the check.
 *   3. Output files live for "at least seven days". So the bytes are copied
 *      into our own Storage on completion and never linked. A plan whose day 30
 *      pointed at a provider URL would find it gone.
 */

const BASE = "https://api.higgsfield.ai";

/** Text to video, cheapest of the endpoints that does it in one call. Held here
 *  as a constant because it is a choice, not a fact -- a better default is a
 *  one-line change and no migration. */
export const DEFAULT_MODEL = "/bytedance/seedance/v1/lite/text-to-video";

export interface Credential {
  keyId: string;
  keySecret: string;
}

export type JobStatus =
  | "queued"
  | "in_progress"
  | "completed"
  | "failed"
  | "nsfw"
  | "canceled";

export interface Submitted {
  requestId: string;
  statusUrl: string;
  cancelUrl: string | null;
  status: JobStatus;
}

export interface Polled {
  status: JobStatus;
  /** Present only when status is "completed". */
  videoUrl: string | null;
  error: string | null;
}

/** The key pair arrives as one string so it can be sealed as one value. */
export function parseCredential(secret: string): Credential {
  const separator = secret.indexOf(":");
  if (separator < 1) {
    throw new Error("expected a credential of the form KEY_ID:KEY_SECRET");
  }
  return {
    keyId: secret.slice(0, separator).trim(),
    keySecret: secret.slice(separator + 1).trim(),
  };
}

function authHeader(credential: Credential): string {
  return `Key ${credential.keyId}:${credential.keySecret}`;
}

/**
 * Is this key real?
 *
 * Asks for the status of a request id that cannot exist. A working key gets a
 * 404 (no such request); a bad one gets a 401 before the id is ever looked at.
 * Deliberately not a generation: a probe that costs money is a probe people
 * avoid running, and this has to run every time a key is saved.
 */
export async function probe(credential: Credential): Promise<{ ok: boolean; detail: string }> {
  const nowhere = "00000000-0000-4000-8000-000000000000";

  try {
    const response = await fetch(`${BASE}/requests/${nowhere}/status`, {
      headers: { Authorization: authHeader(credential) },
    });

    if (response.status === 401 || response.status === 403) {
      return { ok: false, detail: "Higgsfield rejected that key pair." };
    }
    // 404 is the expected answer and means the key was accepted. Anything else
    // in the 2xx-4xx range still proves authentication passed.
    if (response.status < 500) {
      return { ok: true, detail: `verified (${response.status})` };
    }
    return { ok: false, detail: `Higgsfield returned ${response.status}.` };
  } catch (error) {
    return {
      ok: false,
      detail: error instanceof Error ? error.message : "could not reach Higgsfield",
    };
  }
}

export interface SubmitOptions {
  prompt: string;
  /** Where Higgsfield should call back. Passed as a query parameter, which is
   *  the provider's own convention, not ours. */
  webhookUrl?: string;
  model?: string;
  seconds?: number;
}

export async function submit(
  credential: Credential,
  options: SubmitOptions,
): Promise<Submitted> {
  const path = options.model ?? DEFAULT_MODEL;
  const url = new URL(`${BASE}${path}`);
  if (options.webhookUrl) url.searchParams.set("hf_webhook", options.webhookUrl);

  const response = await fetch(url.toString(), {
    method: "POST",
    headers: {
      Authorization: authHeader(credential),
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      prompt: options.prompt,
      // Vertical, because this is going to TikTok and nowhere else yet. Short,
      // because a five-second clip costs a fraction of a ten-second one and the
      // first three seconds are what decide whether anybody watches.
      aspect_ratio: "9:16",
      resolution: "1080",
      duration: options.seconds ?? 5,
    }),
  });

  const body = await response.json().catch(() => ({}));

  if (!response.ok) {
    throw new Error(
      typeof body?.detail === "string"
        ? body.detail
        : `Higgsfield refused the request (${response.status})`,
    );
  }

  if (!body?.request_id || !body?.status_url) {
    throw new Error("Higgsfield accepted the request but said nothing useful about it");
  }

  return {
    requestId: String(body.request_id),
    statusUrl: String(body.status_url),
    cancelUrl: body.cancel_url ? String(body.cancel_url) : null,
    status: (body.status ?? "queued") as JobStatus,
  };
}

/**
 * Reads the truth about a job.
 *
 * Called both by the poller and by the webhook handler -- the webhook body is
 * never trusted, so both paths end up here, and there is only one place where
 * "is it done" is decided.
 */
export async function poll(credential: Credential, statusUrl: string): Promise<Polled> {
  const response = await fetch(statusUrl, {
    headers: { Authorization: authHeader(credential) },
  });

  const body = await response.json().catch(() => ({}));

  if (!response.ok) {
    // A 5xx is the provider having a bad minute, not the job failing. Reported
    // as still running so the poller tries again rather than throwing work away.
    if (response.status >= 500) {
      return { status: "in_progress", videoUrl: null, error: null };
    }
    return {
      status: "failed",
      videoUrl: null,
      error: `Higgsfield returned ${response.status}`,
    };
  }

  const status = (body?.status ?? "in_progress") as JobStatus;

  return {
    status,
    videoUrl: status === "completed" ? findVideoUrl(body) : null,
    error: typeof body?.error === "string" ? body.error : null,
  };
}

/**
 * Finds the output URL wherever this particular model put it.
 *
 * Higgsfield's completed shape varies by output type -- `video.url` for the
 * video models, `results.raw.url` through the SDK, `images[]` for the image
 * ones -- and the endpoint list is long enough that pinning one shape would
 * break the first time somebody picks a different model. So: look in the places
 * it is known to be, and fail loudly rather than returning a plausible nothing.
 */
function findVideoUrl(body: unknown): string | null {
  const seen = new Set<unknown>();

  const walk = (node: unknown, depth: number): string | null => {
    if (depth > 6 || node === null || typeof node !== "object") return null;
    if (seen.has(node)) return null;
    seen.add(node);

    if (Array.isArray(node)) {
      for (const item of node) {
        const found = walk(item, depth + 1);
        if (found) return found;
      }
      return null;
    }

    const record = node as Record<string, unknown>;
    const url = record.url;
    if (typeof url === "string" && /^https?:\/\//.test(url)) return url;

    for (const value of Object.values(record)) {
      const found = walk(value, depth + 1);
      if (found) return found;
    }
    return null;
  };

  return walk(body, 0);
}
