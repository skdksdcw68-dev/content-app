/**
 * fal.ai, over its queue API.
 *
 * Abel, 25 Sep 2026: "we buy from cheaper places, higgsfield is bad... i have
 * fal already best match."
 *
 * WHY THIS IS WORTH HAVING EVEN THOUGH HIGGSFIELD LOOKS CHEAPER PER SECOND.
 * Higgsfield sells a monthly credit pool, and 3,000 credits is roughly ten
 * subscribers -- past that the rate gets 40% worse, and the whole product sits
 * behind one reseller's account. fal bills per second with no pool and no
 * ceiling, so the cost per subscriber stays flat as the number of subscribers
 * grows. One is cheaper at ten customers; the other is the one that still
 * works at a thousand.
 *
 * WHAT MAKES THIS FILE SHORT. `registry.ts` says adding a provider is "a file
 * and one line", and it meant it: nothing above `contract.ts` learns the word
 * "fal". The router compares its prices against Higgsfield's on their own
 * terms because both answer `quote` in their own unit.
 *
 * THE PRICES ARE OURS, NOT QUOTED. fal publishes per-second rates on a
 * pricing page and offers no price-check endpoint, so `quote` answers from the
 * table below with `quoted: false` -- which the picker renders differently
 * from a number the provider committed to. When these drift, they drift in one
 * place.
 */

import {
  type Adapter,
  type Authorization,
  type Cost,
  type Discovery,
  type ModelDescriptor,
  type Polled,
  type SubmitRequest,
  type Submitted,
  unknownVerdict,
  type Verdict,
} from "./contract.ts";

const QUEUE = "https://queue.fal.run";

/**
 * What we offer, and what each second costs us.
 *
 * Read off fal's pricing page on 25 Sep 2026. `perSecond` is OUR cost, in
 * dollars -- the number the plan budget is spent against, never the number
 * shown to a customer.
 *
 * Ordered cheapest first, which is also `rank`: "best available" should mean
 * the cheapest thing that can do the job, not the most expensive.
 */
const CATALOGUE: Array<{
  id: string;
  label: string;
  about: string;
  perSecond: number;
  durations: number[];
  frames: boolean;
  audio: boolean;
}> = [
  {
    id: "fal-ai/wan-25-preview/text-to-video",
    label: "Wan 2.5",
    about: "Sharp and cheap. The everyday choice for a short clip.",
    perSecond: 0.05,
    durations: [5, 10],
    frames: true,
    audio: false,
  },
  {
    id: "fal-ai/kling-video/v2.5-turbo/pro/text-to-video",
    label: "Kling 2.5 Turbo Pro",
    about: "Steady motion and faces that hold together.",
    perSecond: 0.07,
    durations: [5, 10],
    frames: true,
    audio: false,
  },
  {
    id: "fal-ai/veo3.1/fast",
    label: "Google Veo 3.1 Fast",
    about: "Realistic, follows the prompt closely, makes its own sound.",
    perSecond: 0.10,
    durations: [4, 6, 8],
    frames: true,
    audio: true,
  },
  {
    id: "fal-ai/kling-video/v2.1/master/text-to-video",
    label: "Kling 2.1 Master",
    about: "Kling at full quality, for the shot that matters.",
    perSecond: 0.224,
    durations: [5, 10],
    frames: true,
    audio: false,
  },
  {
    id: "fal-ai/veo3.1",
    label: "Google Veo 3.1",
    about: "The best of them, with audio. Costs what that implies.",
    perSecond: 0.40,
    durations: [4, 6, 8],
    frames: true,
    audio: true,
  },
];

/** Seconds a request will be billed for, from the options or the model's own
 *  default. Never guessed at zero: an unpriced job is how a budget is spent
 *  without being counted. */
function seconds(request: SubmitRequest, fallback: number): number {
  const asked = request.options?.duration;
  const value = typeof asked === "number" ? asked : Number(asked);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function entry(id: string) {
  return CATALOGUE.find((model) => model.id === id);
}

async function call(
  auth: Authorization,
  method: string,
  url: string,
  body?: unknown,
): Promise<{ status: number; body: any }> {
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Key ${auth.secret}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  const text = await response.text();
  let parsed: unknown = text;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    // Left as text. An adapter that throws on an unparseable error body turns
    // a bad gateway into a crash with no verdict attached.
  }
  return { status: response.status, body: parsed };
}

export const falAdapter: Adapter = {
  slug: "fal",

  /**
   * fal has no "what can this key do" endpoint -- a key either works or does
   * not, against any model. So discovery proves the key and returns the models
   * we have chosen to offer, rather than pretending to enumerate theirs.
   *
   * The proof matters: without it a wrong key discovers a full catalogue and
   * fails on the first generation, which is exactly how this project spent
   * three weeks thinking it had a working generator.
   */
  async discover(auth: Authorization): Promise<Discovery> {
    const { status, body } = await call(auth, "GET", `${QUEUE}/fal-ai/wan-25-preview/text-to-video/requests/none`);
    // 401/403 means the key is wrong. 404 means the key was accepted and the
    // request id simply does not exist, which is the answer we want.
    if (status === 401 || status === 403) {
      throw new Error(`fal refused the key: ${JSON.stringify(body).slice(0, 160)}`);
    }

    const models: ModelDescriptor[] = CATALOGUE.map((model, index) => ({
      capability: "video_generation",
      external_id: model.id,
      label: model.label,
      metadata: {
        description: model.about,
        cost: {
          unit: "per_second",
          amount: model.perSecond,
          basis: "per second of finished video",
          quoted: false,
        } satisfies Cost,
        constraints: {
          durations: model.durations,
          aspectRatios: ["9:16", "1:1", "16:9"],
          resolutions: ["720p"],
          notes: model.audio ? undefined : ["No sound"],
          defaults: { duration: model.durations[0], resolution: "720p" },
        },
        // Read by the composer to decide whether to offer a first and last
        // frame, rather than guessing from the name.
        frames: model.frames,
      },
      rank: index,
    }));

    return { accountLabel: "fal.ai", externalAccountId: null, models };
  },

  async submit(auth: Authorization, request: SubmitRequest): Promise<Submitted> {
    const model = entry(request.model);
    const length = seconds(request, model?.durations[0] ?? 5);

    const input: Record<string, unknown> = {
      prompt: request.prompt,
      duration: length,
      ...(request.options ?? {}),
    };

    // References go in under the names fal uses for them. A start and end
    // frame are separate fields, not a list, so they are named here rather
    // than passed through.
    const images = (request.references ?? []).filter((r) => r.kind === "image" && r.url);
    if (images[0]?.url) input.image_url = images[0].url;
    if (images[1]?.url) input.end_image_url = images[1].url;

    const { status, body } = await call(
      auth,
      "POST",
      `${QUEUE}/${request.model}${request.webhookUrl ? `?fal_webhook=${encodeURIComponent(request.webhookUrl)}` : ""}`,
      input,
    );

    if (status >= 400) {
      const verdict = falAdapter.classify(status, body);
      throw Object.assign(new Error(verdict.detail), { status, verdict });
    }

    const ref = body?.request_id;
    if (typeof ref !== "string") throw new Error("fal accepted the job but named no request id");

    return {
      ref,
      statusUrl: typeof body?.status_url === "string" ? body.status_url : undefined,
      state: "queued",
      capability: request.capability,
      charged: {
        unit: "usd",
        amount: Number((length * (model?.perSecond ?? 0)).toFixed(4)),
        basis: `${length}s at $${model?.perSecond ?? "?"}/s`,
        quoted: false,
      },
    };
  },

  async poll(auth: Authorization, submitted: Submitted): Promise<Polled> {
    const where = submitted.statusUrl ?? `${QUEUE}/requests/${submitted.ref}/status`;
    const { status, body } = await call(auth, "GET", where);

    if (status >= 400) {
      return { state: "failed", verdict: falAdapter.classify(status, body) };
    }

    const state = String(body?.status ?? "").toUpperCase();
    if (state === "IN_QUEUE") return { state: "queued" };
    if (state === "IN_PROGRESS") return { state: "running" };

    // Done. The status call does not carry the output, so the result is read
    // from the response url fal handed back.
    const resultUrl = typeof body?.response_url === "string"
      ? body.response_url
      : `${QUEUE}/requests/${submitted.ref}`;
    const result = await call(auth, "GET", resultUrl);
    if (result.status >= 400) {
      return { state: "failed", verdict: falAdapter.classify(result.status, result.body) };
    }

    const video = result.body?.video ?? result.body?.videos?.[0];
    const url = video?.url ?? result.body?.url;
    if (typeof url !== "string") {
      return {
        state: "failed",
        verdict: {
          code: "bad_output",
          retryable: false,
          tryAnotherModel: true,
          tryAnotherProvider: true,
          detail: `fal reported ${state} with no video: ${JSON.stringify(result.body).slice(0, 200)}`,
        },
      };
    }

    return {
      state: "done",
      outputUrl: url,
      outputMime: typeof video?.content_type === "string" ? video.content_type : "video/mp4",
    };
  },

  /**
   * What this exact job costs us, from the published rate and the length asked
   * for. `quoted: false` because fal has no price-check call -- this is our
   * reading of their pricing page, and the picker says so.
   */
  quote(_auth: Authorization, request: SubmitRequest): Promise<Cost | null> {
    const model = entry(request.model);
    if (!model) return Promise.resolve(null);
    const length = seconds(request, model.durations[0]);
    return Promise.resolve({
      unit: "usd",
      amount: Number((length * model.perSecond).toFixed(4)),
      basis: `${length}s at $${model.perSecond}/s`,
      quoted: false,
    });
  },

  // No balance: fal bills per use against a card rather than holding a
  // balance, and an adapter that cannot ask must not answer. `canAffordVideo`
  // treats "would not say" as permission to continue, which is right here --
  // there is no pool to run out of.

  classify(status: number, body: unknown): Verdict {
    const said = typeof body === "string" ? body : JSON.stringify(body ?? "");
    const words = said.toLowerCase();

    if (status === 401 || status === 403) {
      return {
        code: "bad_key",
        retryable: false,
        tryAnotherModel: false,
        tryAnotherProvider: true,
        detail: said.slice(0, 300),
      };
    }
    if (status === 402 || words.includes("insufficient") || words.includes("balance")) {
      return {
        code: "no_credits",
        retryable: false,
        tryAnotherModel: false,
        tryAnotherProvider: true,
        detail: said.slice(0, 300),
      };
    }
    if (status === 429) {
      return {
        code: "rate_limited",
        retryable: true,
        tryAnotherModel: false,
        tryAnotherProvider: true,
        detail: said.slice(0, 300),
      };
    }
    if (status === 404) {
      return {
        code: "no_models",
        retryable: false,
        tryAnotherModel: true,
        tryAnotherProvider: true,
        detail: said.slice(0, 300),
      };
    }
    // fal returns 422 with a validation body when the prompt or the settings
    // are refused. Another model of the same shape will refuse it too.
    if (status === 422) {
      return {
        code: "refused",
        retryable: false,
        tryAnotherModel: false,
        tryAnotherProvider: false,
        detail: said.slice(0, 300),
      };
    }
    return unknownVerdict(status, said.slice(0, 300));
  },
};
