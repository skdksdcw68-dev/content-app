/**
 * OpenAI's own Images API, as a house generator beside fal.
 *
 * Netro, 19 Oct 2026: "why don't we use the GPT 2 model inside the OpenAI API?
 * No fal needed for that, and we get it for a discount too." He was right on
 * both counts: `gpt-image-2` is on our OpenAI key, a low-quality picture costs
 * half a cent, and it works when fal's balance is empty.
 *
 * It answers under the SAME model id fal does (`openai/gpt-image-2`), so the
 * app, the pickers and every old build keep naming one model. The router sees
 * two places that can make it and tries this one first (rank), then fal --
 * a refusal on one is a reason to try the other, an empty balance on one is
 * not a reason to fail.
 *
 * Synchronous: a picture takes 10-60 seconds and the API answers with the
 * finished bytes, so `submit` returns a terminal state with the picture as a
 * data URL (JPEG, about a megapixel -- a few hundred KB) and nothing is ever
 * polled. `charged` is the EXACT cost, from the tokens the API reports.
 */

import type {
  Adapter,
  Authorization,
  Cost,
  Discovery,
  ModelDescriptor,
  Polled,
  SubmitRequest,
  Submitted,
  Verdict,
} from "./contract.ts";
import { unknownVerdict } from "./contract.ts";

/** The meter's unit, in dollars (`_shared/usage.ts` CREDIT_USD). */
const METER_UNIT_USD = 0.0001;

/** The name fal uses, kept so one model has one id everywhere. */
export const OPENAI_IMAGE_ID = "openai/gpt-image-2";
const API_MODEL = "gpt-image-2";

/**
 * Dollars per million tokens. Text and picture input, and picture output. The
 * published figures disagree by a few percent between sources ($30 or $32 an
 * output million), so the higher is used: a meter that rounds against us is
 * safe, one that rounds in our favour quietly eats a plan's margin.
 */
const PER_MILLION = { textIn: 5, imageIn: 8, imageOut: 32 };

/** What each quality costs at about a megapixel, for the price shown BEFORE
 *  the picture exists. The real cost replaces it afterwards, from the tokens. */
const TIERS: Record<string, { quality: string; estimate: number }> = {
  Low: { quality: "low", estimate: 0.012 },
  Medium: { quality: "medium", estimate: 0.055 },
  High: { quality: "high", estimate: 0.21 },
};
const DEFAULT_TIER = "Medium";

const ASPECTS = ["9:16", "3:4", "1:1", "4:3", "16:9"];
/** A request this long gives up: the platform's own wall clock is nearer. */
const TIMEOUT_MS = 110_000;

function billable(usd: number): { amount: number; ours: number } {
  const units = Math.max(1, Math.ceil(usd / METER_UNIT_USD - 1e-9));
  return { amount: Number((units * METER_UNIT_USD).toFixed(4)), ours: Number(usd.toFixed(4)) };
}

function tierOf(request: SubmitRequest): string {
  const said = String(request.options?.resolution ?? request.options?.quality ?? "").toLowerCase();
  return Object.keys(TIERS).find((name) => name.toLowerCase() === said) ?? DEFAULT_TIER;
}

function countOf(request: SubmitRequest): number {
  const asked = Number(request.options?.count ?? 1);
  return Math.max(1, Math.min(4, Math.round(Number.isFinite(asked) ? asked : 1)));
}

/** "WxH" for a frame: about a megapixel, in multiples of 16 (the API's rule,
 *  checked live at 1152x2048 and 1024x1536). */
function sizeFor(request: SubmitRequest): string {
  const said = request.options?.aspect ?? request.options?.aspect_ratio;
  const aspect = typeof said === "string" && /^\d+:\d+$/.test(said) ? said : "9:16";
  const [w, h] = aspect.split(":").map(Number);
  if (!(w > 0 && h > 0)) return "752x1328";
  const width = Math.max(512, Math.round(Math.sqrt(1_000_000 * (w / h)) / 16) * 16);
  const height = Math.max(512, Math.round(Math.sqrt(1_000_000 * (h / w)) / 16) * 16);
  return `${width}x${height}`;
}

/** What the API's own token counts come to, in dollars. */
function costOfUsage(usage: any): number | null {
  if (!usage || typeof usage !== "object") return null;
  const details = usage.input_tokens_details ?? {};
  const textIn = Number(details.text_tokens ?? usage.input_tokens ?? 0);
  const imageIn = Number(details.image_tokens ?? 0);
  const out = Number(usage.output_tokens ?? 0);
  if (![textIn, imageIn, out].every(Number.isFinite)) return null;
  return (textIn * PER_MILLION.textIn + imageIn * PER_MILLION.imageIn + out * PER_MILLION.imageOut) / 1_000_000;
}

function fail(status: number, message: string): Error {
  return Object.assign(new Error(message), { status });
}

/** The API's error, as one line carrying both its code and its words, so
 *  `classify` can read it back and the person is shown the real reason. */
function describeError(body: any, status: number): string {
  const error = body?.error ?? body;
  const code = typeof error?.code === "string" ? error.code : typeof error?.type === "string" ? error.type : "";
  const message = typeof error?.message === "string" ? error.message : `OpenAI answered ${status}`;
  return code ? `${code}: ${message}` : message;
}

async function dataUrl(mime: string, base64: string): Promise<string> {
  return `data:${mime};base64,${base64}`;
}

async function send(auth: Authorization, path: string, init: RequestInit): Promise<{ status: number; body: any }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(`${auth.endpoint.replace(/\/$/, "")}${path}`, {
      ...init,
      headers: { Authorization: `Bearer ${auth.secret}`, ...(init.headers ?? {}) },
      signal: controller.signal,
    });
    const text = await response.text();
    let body: unknown = text;
    try {
      body = JSON.parse(text);
    } catch {
      // Not JSON: kept as the text it was.
    }
    return { status: response.status, body };
  } catch (thrown) {
    if ((thrown as Error)?.name === "AbortError") {
      throw fail(504, "timeout: OpenAI took too long to make that picture");
    }
    throw thrown;
  } finally {
    clearTimeout(timer);
  }
}

export function describeOpenAI(): ModelDescriptor[] {
  return [{
    capability: "image_generation",
    external_id: OPENAI_IMAGE_ID,
    label: "GPT Image 2",
    metadata: {
      description: "OpenAI's newest. The most accurate, and the best with text.",
      cost: {
        unit: "per_image",
        amount: TIERS[DEFAULT_TIER].estimate,
        basis: "per image",
        quoted: false,
      } satisfies Cost,
      constraints: {
        aspectRatios: ASPECTS,
        resolutions: Object.keys(TIERS),
        defaults: { resolution: DEFAULT_TIER },
        audio: false,
        audioSwitch: false,
        takesPicture: true,
        endFrame: false,
        negativePrompt: false,
      },
      medias: [{ roles: ["image"] }],
      frames: false,
    },
    // Ahead of fal's copy of the same model, whatever its rank is.
    rank: -10,
  }];
}

export const openaiAdapter: Adapter = {
  slug: "openai",

  async discover(auth: Authorization): Promise<Discovery> {
    const { status, body } = await send(auth, `/models/${API_MODEL}`, { method: "GET" });
    if (status >= 400) throw fail(status, describeError(body, status));
    return {
      accountLabel: "OpenAI",
      externalAccountId: null,
      models: describeOpenAI(),
    };
  },

  async submit(auth: Authorization, request: SubmitRequest): Promise<Submitted> {
    if (request.capability !== "image_generation") {
      throw Object.assign(new Error("OpenAI makes pictures here, not that"), {
        status: 422,
        verdict: unknownVerdict(422, "not a picture"),
      });
    }

    const tier = TIERS[tierOf(request)];
    const count = countOf(request);
    const size = sizeFor(request);
    const pictures = (request.references ?? [])
      .filter((reference) => reference.kind === "image" && reference.url)
      .map((reference) => reference.url as string)
      .slice(0, 4);

    let result: { status: number; body: any };
    if (pictures.length > 0) {
      // Working from a picture is the EDIT endpoint, multipart.
      const form = new FormData();
      form.append("model", API_MODEL);
      form.append("prompt", request.prompt);
      form.append("size", size);
      form.append("quality", tier.quality);
      form.append("n", String(count));
      form.append("output_format", "jpeg");
      form.append("output_compression", "92");
      for (const [index, url] of pictures.entries()) {
        const fetched = await fetch(url);
        if (!fetched.ok) throw fail(422, `bad_request: could not read reference picture ${index + 1}`);
        const blob = await fetched.blob();
        form.append("image[]", blob, `reference-${index + 1}.${blob.type.includes("png") ? "png" : "jpg"}`);
      }
      result = await send(auth, "/images/edits", { method: "POST", body: form });
    } else {
      result = await send(auth, "/images/generations", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          model: API_MODEL,
          prompt: request.prompt,
          size,
          quality: tier.quality,
          n: count,
          output_format: "jpeg",
          output_compression: 92,
        }),
      });
    }

    if (result.status >= 400) throw fail(result.status, describeError(result.body, result.status));

    const first = result.body?.data?.[0]?.b64_json;
    if (typeof first !== "string" || first.length < 100) {
      throw fail(502, "bad_output: OpenAI answered without a picture");
    }

    const spent = costOfUsage(result.body?.usage);
    return {
      // Nothing to poll: the work is finished. The id is for the logs.
      ref: `openai-${crypto.randomUUID()}`,
      state: "done",
      capability: request.capability,
      outputUrl: await dataUrl("image/jpeg", first),
      charged: {
        unit: "usd",
        // The tokens' own price when the API said them; the tier's estimate
        // only if it did not.
        ...billable(spent ?? TIERS[tierOf(request)].estimate * count),
        basis: count > 1 ? `${count} images` : "1 image",
        quoted: spent !== null,
      },
    };
  },

  async poll(_auth: Authorization, submitted: Submitted): Promise<Polled> {
    // `submit` already finished it.
    return { state: "done", outputUrl: submitted.outputUrl, outputMime: "image/jpeg" };
  },

  async quote(_auth: Authorization, request: SubmitRequest): Promise<Cost | null> {
    if (request.capability !== "image_generation") return null;
    const each = TIERS[tierOf(request)].estimate;
    return {
      unit: "usd",
      ...billable(each * countOf(request)),
      basis: "per image",
      quoted: false,
    };
  },

  classify(status: number, body: unknown): Verdict {
    const said = typeof body === "string"
      ? body
      : typeof (body as { detail?: unknown })?.detail === "string"
      ? String((body as { detail: string }).detail)
      : JSON.stringify(body ?? "");
    const words = said.toLowerCase();
    const detail = said.slice(0, 300);

    if (status === 401 || status === 403 || words.includes("invalid_api_key") || words.includes("incorrect api key")) {
      return { code: "bad_key", retryable: false, tryAnotherModel: false, tryAnotherProvider: true, detail };
    }
    // An empty or capped account. A 429 can be either this or a rate limit;
    // the code in the words says which.
    if (
      status === 402 || words.includes("insufficient_quota") || words.includes("billing_hard_limit") ||
      words.includes("exceeded your current quota")
    ) {
      return { code: "no_credits", retryable: false, tryAnotherModel: false, tryAnotherProvider: true, detail };
    }
    if (status === 429) {
      return { code: "rate_limited", retryable: true, tryAnotherModel: false, tryAnotherProvider: true, detail };
    }
    // The safety system. Another model of OpenAI's will say the same, and the
    // person is told the provider's own reason.
    if (
      words.includes("moderation_blocked") || words.includes("content_policy") ||
      words.includes("safety system") || words.includes("safety_violation")
    ) {
      return { code: "refused", retryable: false, tryAnotherModel: false, tryAnotherProvider: false, detail };
    }
    if (words.includes("timeout") || status === 504) {
      return { code: "provider_down", retryable: true, tryAnotherModel: false, tryAnotherProvider: true, detail };
    }
    return unknownVerdict(status, detail);
  },
};
