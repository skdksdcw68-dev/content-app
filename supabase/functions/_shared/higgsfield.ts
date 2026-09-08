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

/**
 * The models we can actually post with, cheapest first.
 *
 * Two things make this a list of objects rather than a list of paths.
 *
 * The first is that **the bodies are not interchangeable**. Higgsfield's
 * text-to-video endpoints share exactly one field -- `prompt`. Kling takes a
 * duration of 5 or 10 and no resolution; Sora takes 4, 8 or 12 and spells its
 * resolution "720p"; Seedance takes any integer and spells it "1080". Sending
 * one body to all of them trades a 404 for a 422 and looks identical from the
 * outside.
 *
 * The second is that **most of their catalogue cannot do vertical**. Of the
 * eleven text-to-video endpoints in the spec, only these five accept an
 * `aspect_ratio` of 9:16 at all -- Kling 2.5 Turbo and every Minimax Hailuo
 * model have no aspect ratio field whatsoever, so they can only produce
 * landscape. For a product that posts to TikTok that makes them unusable, not
 * merely worse, and they are left out rather than left in as a bad last resort.
 */
export interface VideoModel {
  /** The endpoint path, which on this API *is* the model identifier. */
  path: string;
  /** What to call it when a person has to read about it going wrong. */
  label: string;
  /** This model's own body. See above for why each one builds its own. */
  body(prompt: string, seconds: number): Record<string, unknown>;
}

/** Snaps a requested length to the nearest one a model will accept. Asking
 *  Sora for five seconds is a 422; asking it for four is a video. */
function nearest(seconds: number, allowed: number[]): number {
  return allowed.reduce((best, option) =>
    Math.abs(option - seconds) < Math.abs(best - seconds) ? option : best
  );
}

export const MODELS: readonly VideoModel[] = [
  {
    path: "/bytedance/seedance/v1/lite/text-to-video",
    label: "Seedance Lite",
    body: (prompt, seconds) => ({
      prompt,
      aspect_ratio: "9:16",
      resolution: "1080",
      duration: seconds,
    }),
  },
  {
    path: "/bytedance/seedance/v1/pro/fast/text-to-video",
    label: "Seedance Pro",
    body: (prompt, seconds) => ({
      prompt,
      aspect_ratio: "9:16",
      resolution: "1080",
      duration: seconds,
    }),
  },
  {
    path: "/kling-video/v2.1/master/text-to-video",
    label: "Kling 2.1 Master",
    body: (prompt, seconds) => ({
      prompt,
      aspect_ratio: "9:16",
      duration: nearest(seconds, [5, 10]),
    }),
  },
  {
    path: "/sora-2/text-to-video",
    label: "Sora 2",
    body: (prompt, seconds) => ({
      prompt,
      aspect_ratio: "9:16",
      resolution: "720p",
      duration: nearest(seconds, [4, 8, 12]),
    }),
  },
  {
    path: "/sora-2/text-to-video/pro",
    label: "Sora 2 Pro",
    body: (prompt, seconds) => ({
      prompt,
      aspect_ratio: "9:16",
      resolution: "1080p",
      duration: nearest(seconds, [4, 8, 12]),
    }),
  },
];

/** Kept so a caller that stored a path can still name a model. */
export function modelFor(path: string): VideoModel | undefined {
  return MODELS.find((model) => model.path === path);
}

/**
 * What a refusal means for the job that hit it.
 *
 * Straight out of Higgsfield's own error table, because guessing here is how
 * you either give up on a working account or hammer a broken one:
 *
 *   401/403  the key or the balance. No other model fixes either, so stop.
 *   404      "not found *for this account*" -- this model, not the account.
 *   400/422  this model will not take this body. Ours should be right, so it
 *            is worth trying the next rather than failing the day outright.
 *   423/503  temporarily blocked, or disabled. Another model may be up.
 *   5xx      their bad minute. Not a verdict on anything -- come back later.
 */
export class Refused extends Error {
  constructor(
    message: string,
    /** True when nothing about this is settled and the job should run again. */
    readonly retryable: boolean,
  ) {
    super(message);
    this.name = "Refused";
  }
}

type Verdict = "try_next" | "stop" | "retry_later";

function verdictFor(status: number): Verdict {
  if (status === 401 || status === 403) return "stop";
  if (status === 404 || status === 400 || status === 422) return "try_next";
  if (status === 423 || status === 503) return "try_next";
  if (status >= 500) return "retry_later";
  return "stop";
}

/**
 * Said the way somebody who has not read this file would need to hear it --
 * without throwing away what the provider actually said.
 *
 * The first version of this replaced their words with ours, and that turned out
 * to be exactly wrong: a 403 was reported as "out of credits" on our authority
 * alone, and when topping up did not fix it there was nothing left to read. Our
 * sentence tells someone what to do; theirs is the evidence for it, and the
 * evidence is the half you need when the advice is wrong.
 */
function humanly(status: number, model: string, detail: string): string {
  const said = detail ? ` Higgsfield said: "${detail}" (${model}, ${status}).` : "";

  if (status === 401) {
    return `Higgsfield rejected your key. Reconnect it under You → Generators.${said}`;
  }
  if (status === 403) {
    return "Higgsfield refused this on billing or permissions — check credits and " +
      `model access for your API key at cloud.higgsfield.ai.${said}`;
  }
  return detail || `Higgsfield returned ${status} for ${model}.`;
}

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
  /** Which model took it. Remembered against the credential so the next job
   *  starts where this one finished instead of walking the list again. */
  model: string;
  modelLabel: string;
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
  /** A model known to have worked for this credential before. Tried first, and
   *  the rest of the list still follows if it has since been withdrawn. */
  preferModel?: string;
  /** Short by default: a five-second clip costs a fraction of a ten-second one,
   *  and the first three seconds decide whether anybody watches. */
  seconds?: number;
}

/** One attempt against one model, kept so a total failure can say what it
 *  actually tried rather than "generation failed". */
interface Attempt {
  label: string;
  status: number;
  detail: string;
}

async function submitTo(
  credential: Credential,
  model: VideoModel,
  options: SubmitOptions,
): Promise<{ ok: true; submitted: Submitted } | { ok: false; attempt: Attempt; verdict: Verdict }> {
  const url = new URL(`${BASE}${model.path}`);
  if (options.webhookUrl) url.searchParams.set("hf_webhook", options.webhookUrl);

  const response = await fetch(url.toString(), {
    method: "POST",
    headers: {
      Authorization: authHeader(credential),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(model.body(options.prompt, options.seconds ?? 5)),
  });

  const body = await response.json().catch(() => ({}));

  if (!response.ok) {
    const detail = typeof body?.detail === "string"
      ? body.detail
      : `Higgsfield returned ${response.status}`;
    return {
      ok: false,
      attempt: { label: model.label, status: response.status, detail },
      verdict: verdictFor(response.status),
    };
  }

  if (!body?.request_id || !body?.status_url) {
    // Accepted, but with nothing to poll. Treated as this model misbehaving
    // rather than as a submission, because a job with no status_url can never
    // finish and would sit in the queue until a human noticed.
    return {
      ok: false,
      attempt: {
        label: model.label,
        status: 200,
        detail: "accepted the request but returned no status URL",
      },
      verdict: "try_next",
    };
  }

  return {
    ok: true,
    submitted: {
      requestId: String(body.request_id),
      statusUrl: String(body.status_url),
      cancelUrl: body.cancel_url ? String(body.cancel_url) : null,
      status: (body.status ?? "queued") as JobStatus,
      model: model.path,
      modelLabel: model.label,
    },
  };
}

/**
 * Gets the video started, on whichever model this account can actually use.
 *
 * The version of this that only knew one model is what put three days of
 * Autopilot on the floor: Seedance answered `model_not_found`, which is
 * Higgsfield's way of saying "not on your plan", and the day was over. One
 * provider's catalogue changing underneath a user is a Tuesday, not an
 * exception, so it is handled here rather than reported.
 */
export async function submit(
  credential: Credential,
  options: SubmitOptions,
): Promise<Submitted> {
  // The one that worked last time first, then everything else in price order.
  // Not *only* the remembered one: model access is granted and withdrawn on
  // Higgsfield's side, so a stale memory must not become a permanent failure.
  const preferred = options.preferModel ? modelFor(options.preferModel) : undefined;
  const order = preferred
    ? [preferred, ...MODELS.filter((model) => model.path !== preferred.path)]
    : [...MODELS];

  const attempts: Attempt[] = [];

  for (const model of order) {
    const result = await submitTo(credential, model, options);
    if (result.ok) return result.submitted;

    attempts.push(result.attempt);

    if (result.verdict === "stop") {
      throw new Refused(
        humanly(result.attempt.status, result.attempt.label, result.attempt.detail),
        false,
      );
    }
    if (result.verdict === "retry_later") {
      throw new Refused("Higgsfield is having trouble right now. This will be tried again.", true);
    }
  }

  // Every model refused. That is an account fact, not a transient one, so the
  // job is not retried -- and the message says where to go, because "no models
  // available" with no address is a dead end for the person reading it.
  const tried = attempts.map((a) => `${a.label} (${a.status})`).join(", ");
  throw new Refused(
    "Your Higgsfield account cannot use any of the vertical video models this app supports. " +
      `Check your plan and model access at cloud.higgsfield.ai. Tried: ${tried}.`,
    false,
  );
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
