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
interface Entry {
  id: string;
  label: string;
  about: string;
  /** Dollars per second of output, by resolution. 🔴 Not one number: Wan is
   *  $0.05 at 480p, $0.10 at 720p and $0.15 at 1080p, and quoting the cheapest
   *  while submitting at the model's own default -- which is 1080p -- would
   *  have shown a price three times under what it charged. */
  perSecond: Record<string, number>;
  durations: number[];
  /** What we ask for unless told otherwise. Never left to the model: fal
   *  defaults Wan to 1080p and 16:9, and 16:9 is the wrong shape for every
   *  video this app makes. */
  resolution: string;
  /** 🔴 The schema says `duration` is a STRING ("5"), not a number. Sending 5
   *  is a 422 and the job never starts. */
  durationAsText: boolean;
  /** The separate endpoint that takes a starting picture. 🔴 A text-to-video
   *  endpoint does not accept one and does not complain -- it ignores it and
   *  makes something unrelated, which is worse than refusing. */
  imageEndpoint?: string;
  frames: boolean;
  audio: boolean;
}

const CATALOGUE: Entry[] = [
  {
    id: "fal-ai/wan-25-preview/text-to-video",
    label: "Wan 2.5",
    about: "Sharp and cheap. The everyday choice for a short clip.",
    perSecond: { "480p": 0.05, "720p": 0.10, "1080p": 0.15 },
    durations: [5, 10],
    resolution: "720p",
    durationAsText: true,
    imageEndpoint: "fal-ai/wan-25-preview/image-to-video",
    frames: true,
    audio: false,
  },
  {
    id: "fal-ai/kling-video/v2.5-turbo/pro/text-to-video",
    label: "Kling 2.5 Turbo Pro",
    about: "Steady motion and faces that hold together.",
    perSecond: { "720p": 0.07 },
    durations: [5, 10],
    resolution: "720p",
    durationAsText: true,
    frames: false,
    audio: false,
  },
  {
    id: "fal-ai/veo3.1/fast",
    label: "Google Veo 3.1 Fast",
    about: "Realistic, follows the prompt closely, makes its own sound.",
    perSecond: { "720p": 0.10, "1080p": 0.15 },
    durations: [4, 6, 8],
    resolution: "720p",
    durationAsText: true,
    frames: false,
    audio: true,
  },
  {
    id: "fal-ai/kling-video/v2.1/master/text-to-video",
    label: "Kling 2.1 Master",
    about: "Kling at full quality, for the shot that matters.",
    perSecond: { "720p": 0.224 },
    durations: [5, 10],
    resolution: "720p",
    durationAsText: true,
    frames: false,
    audio: false,
  },
  {
    id: "fal-ai/veo3.1",
    label: "Google Veo 3.1",
    about: "The best of them, with audio. Costs what that implies.",
    perSecond: { "720p": 0.40, "1080p": 0.40 },
    durations: [4, 6, 8],
    resolution: "720p",
    durationAsText: true,
    frames: false,
    audio: true,
  },
];

/** What a second costs at the resolution actually being asked for. */
function rate(model: Entry, resolution: string): number {
  return model.perSecond[resolution] ?? model.perSecond[model.resolution] ??
    Object.values(model.perSecond)[0];
}

/** The resolution this request will run at: what was asked for if the model
 *  offers it, else the model's own default. Never fal's default, which is the
 *  most expensive one it has. */
function resolutionFor(model: Entry, request: SubmitRequest): string {
  const asked = String(request.options?.resolution ?? "");
  return model.perSecond[asked] ? asked : model.resolution;
}

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
          amount: rate(model, model.resolution),
          basis: "per second of finished video",
          quoted: false,
        } satisfies Cost,
        constraints: {
          durations: model.durations,
          aspectRatios: ["9:16", "1:1", "16:9"],
          resolutions: Object.keys(model.perSecond),
          notes: model.audio ? undefined : ["No sound"],
          defaults: { duration: model.durations[0], resolution: model.resolution },
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

    const resolution = model ? resolutionFor(model, request) : "720p";

    // 🔴 Built field by field, NOT spread from `options`. The schema rejects
    // unknown keys, and `options` carries this app's own words -- voiceover,
    // captions, aspect -- which are instructions for the writer, not for fal.
    const input: Record<string, unknown> = {
      prompt: request.prompt,
      // A string. The schema says `duration: "5" | "10"`, and sending the
      // number is a 422 with nothing generated.
      duration: model?.durationAsText === false ? length : String(length),
      resolution,
      // Vertical, always, unless something explicitly asks otherwise. fal
      // defaults to 16:9 and every video this app makes is for a phone.
      aspect_ratio: typeof request.options?.aspect === "string" ? request.options.aspect : "9:16",
    };
    const negative = request.options?.negative_prompt;
    if (typeof negative === "string" && negative.trim()) input.negative_prompt = negative.trim();

    // 🔴 A picture means a different endpoint, not an extra field.
    //
    // Abel, 25 Sep 2026, having attached a photo: "Using the provided photo,
    // make it actually the reaction." A text-to-video endpoint has no
    // `image_url` and does not refuse one -- it ignores it and makes something
    // unrelated, so the video comes back looking fine and having nothing to do
    // with what was asked for. That is the worst kind of failure: silent.
    const picture = (request.references ?? []).find((r) => r.kind === "image" && r.url)?.url;
    let endpoint = request.model;
    if (picture && model?.imageEndpoint) {
      endpoint = model.imageEndpoint;
      input.image_url = picture;
      // Image-to-video takes its shape from the picture, and sending an
      // aspect ratio it does not declare is a 422.
      delete input.aspect_ratio;
    } else if (picture) {
      // Asked to work from a picture by a model that cannot. Said, not
      // silently dropped -- the caller can pick another model.
      throw Object.assign(new Error(`${model?.label ?? request.model} cannot work from a picture`), {
        status: 422,
        verdict: {
          code: "refused" as const,
          retryable: false,
          tryAnotherModel: true,
          tryAnotherProvider: false,
          detail: "that model makes video from words only",
        },
      });
    }

    const { status, body } = await call(
      auth,
      "POST",
      `${QUEUE}/${endpoint}${request.webhookUrl ? `?fal_webhook=${encodeURIComponent(request.webhookUrl)}` : ""}`,
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
      // 🔴 Always set, never left to a fallback. fal's status path is scoped
      // to the MODEL -- `/{model}/requests/{id}/status`, not
      // `/requests/{id}/status` -- so a generic fallback 404s and the job
      // polls forever. fal returns `status_url`; this builds the same thing if
      // it ever stops.
      statusUrl: typeof body?.status_url === "string"
        ? body.status_url
        : `${QUEUE}/${endpoint}/requests/${ref}/status`,
      state: "queued",
      capability: request.capability,
      charged: {
        unit: "usd",
        amount: Number((length * (model ? rate(model, resolution) : 0)).toFixed(4)),
        basis: `${length}s of ${resolution} at ${model ? rate(model, resolution) : "?"}/s`,
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
    const resolution = resolutionFor(model, request);
    const each = rate(model, resolution);
    return Promise.resolve({
      unit: "usd",
      amount: Number((length * each).toFixed(4)),
      basis: `${length}s of ${resolution} at ${each}/s`,
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
