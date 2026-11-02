/**
 * ElevenLabs, over a pasted API key.
 *
 * Abel, 2 Nov 2026, after asking for a voice and pasting his key: "when I pass a
 * key from ElevenLabs, it doesn't know or it doesn't work." The pasted-key door
 * only knew Higgsfield's id-and-secret pair, so an ElevenLabs key was tried as
 * half of one and refused. This is the other door: one key, the person's own
 * voices and plan, speech out.
 *
 * Synchronous, like OpenAI's images: text-to-speech answers with the finished
 * audio, so `submit` returns a terminal state with the clip as a data URL and
 * nothing is polled. What it costs is the person's own ElevenLabs allowance, so
 * the cost is `allowance`, never a price we invented.
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

/** The speech model. Multilingual v2 reads any language and holds a voice
 *  steady across a long script; the faster models trade that away. */
export const ELEVENLABS_SPEECH_ID = "eleven_multilingual_v2";

/** A request this long gives up: the platform's own wall clock is nearer. */
const TIMEOUT_MS = 100_000;

/** How many of the person's voices are offered by name. */
const MAX_VOICES = 40;

interface Voice {
  id: string;
  name: string;
}

function fail(status: number, message: string): Error {
  return Object.assign(new Error(message), { status });
}

/** The API's error as one line carrying its status word and its message. */
function describeError(body: any, status: number): string {
  const detail = body?.detail ?? body;
  const code = typeof detail?.status === "string" ? detail.status : "";
  const message = typeof detail?.message === "string"
    ? detail.message
    : typeof detail === "string"
    ? detail
    : `ElevenLabs answered ${status}`;
  return code ? `${code}: ${message}` : message;
}

async function send(
  auth: Authorization,
  path: string,
  init: RequestInit,
): Promise<{ status: number; response: Response }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(`${auth.endpoint.replace(/\/$/, "")}${path}`, {
      ...init,
      headers: { "xi-api-key": auth.secret, ...(init.headers ?? {}) },
      signal: controller.signal,
    });
    return { status: response.status, response };
  } catch (thrown) {
    if ((thrown as Error)?.name === "AbortError") {
      throw fail(504, "timeout: ElevenLabs took too long to make that voice");
    }
    throw thrown;
  } finally {
    clearTimeout(timer);
  }
}

async function jsonOf(response: Response): Promise<any> {
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

/** The voices this key can speak with: the library's premade ones and any the
 *  person made or added. */
async function voicesOf(auth: Authorization): Promise<Voice[]> {
  const { status, response } = await send(auth, "/voices", { method: "GET" });
  const body = await jsonOf(response);
  if (status >= 400) throw fail(status, describeError(body, status));
  const list = Array.isArray(body?.voices) ? body.voices : [];
  // Autocast's own account (the house key) speaks with the library's stock
  // voices only: its clones and added voices are private, and everybody can
  // reach this connection.
  const house = auth.secret === Deno.env.get("ELEVENLABS_API_KEY");
  return list
    .filter((voice: any) => !house || voice?.category === "premade")
    .filter((voice: any) => typeof voice?.voice_id === "string" && typeof voice?.name === "string")
    .slice(0, MAX_VOICES)
    .map((voice: any) => ({ id: voice.voice_id as string, name: voice.name as string }));
}

/** Is this key one ElevenLabs accepts? Asked before it is kept, with the same
 *  call discovery makes, so a key that cannot list voices (a restricted key
 *  without that permission) is told so now rather than inside a job. */
export async function probeElevenLabs(key: string): Promise<{ ok: boolean; detail: string }> {
  try {
    const voices = await voicesOf({
      connectionId: "probe",
      secret: key,
      endpoint: "https://api.elevenlabs.io/v1",
    });
    return { ok: true, detail: `${voices.length} voice${voices.length === 1 ? "" : "s"} available` };
  } catch (thrown) {
    const status = Number((thrown as { status?: number })?.status ?? 0);
    const words = String((thrown as Error)?.message ?? "");
    if (status === 401 && /missing_permissions|permission/i.test(words)) {
      return {
        ok: false,
        detail: "That key can't list voices. Turn on voices (read) and text to speech for it in ElevenLabs, or make a new key with full access.",
      };
    }
    if (status === 401 || status === 403) {
      return { ok: false, detail: "ElevenLabs didn't accept that key. Check it was copied whole." };
    }
    return { ok: false, detail: `Couldn't reach ElevenLabs to check it (${words.slice(0, 120) || status}).` };
  }
}

function describeSpeech(voices: Voice[], house: boolean): ModelDescriptor[] {
  return [{
    capability: "voice_generation",
    external_id: ELEVENLABS_SPEECH_ID,
    label: "ElevenLabs voice",
    metadata: {
      description: house ? "Speech in Autocast's voices, any language." : "Speech in your own ElevenLabs voices, any language.",
      cost: {
        unit: "allowance",
        amount: null,
        basis: house ? "included with Autocast" : "from your ElevenLabs plan",
        quoted: false,
      } satisfies Cost,
      constraints: {
        formats: ["mp3"],
        choices: voices.length > 0
          ? [{ name: "voice", label: "Voice", options: voices.map((voice) => voice.name), preset: voices[0].name }]
          : [],
        audio: true,
        takesPicture: false,
        endFrame: false,
        negativePrompt: false,
      },
      medias: [],
      frames: false,
    },
    rank: -5,
  }];
}

export const elevenlabsAdapter: Adapter = {
  slug: "elevenlabs",

  async discover(auth: Authorization): Promise<Discovery> {
    const voices = await voicesOf(auth);
    return {
      accountLabel: "ElevenLabs",
      externalAccountId: null,
      models: describeSpeech(voices, auth.secret === Deno.env.get("ELEVENLABS_API_KEY")),
    };
  },

  async submit(auth: Authorization, request: SubmitRequest): Promise<Submitted> {
    if (request.capability !== "voice_generation" && request.capability !== "audio_generation") {
      throw Object.assign(new Error("ElevenLabs speaks here, it doesn't make that"), {
        status: 422,
        verdict: unknownVerdict(422, "not speech"),
      });
    }
    const text = request.prompt.trim();
    if (!text) throw fail(422, "bad_request: there was nothing to say");

    // The voice: named on the card, or the first the key has. Matched by name,
    // and a raw voice id is accepted as it is.
    const wanted = typeof request.options?.voice === "string" ? request.options.voice.trim() : "";
    const voices = await voicesOf(auth);
    const chosen = voices.find((voice) => voice.name.toLowerCase() === wanted.toLowerCase()) ??
      voices.find((voice) => voice.id === wanted) ??
      voices[0];
    if (!chosen) throw fail(422, "bad_request: this key has no voices to speak with");

    const { status, response } = await send(
      auth,
      `/text-to-speech/${encodeURIComponent(chosen.id)}?output_format=mp3_44100_128`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "audio/mpeg" },
        body: JSON.stringify({ text, model_id: ELEVENLABS_SPEECH_ID }),
      },
    );
    if (status >= 400) throw fail(status, describeError(await jsonOf(response), status));

    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length < 200) throw fail(502, "bad_output: ElevenLabs answered without any audio");

    // Base64 in slices: spreading a whole clip into String.fromCharCode
    // overflows the stack.
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    }

    return {
      ref: `elevenlabs-${crypto.randomUUID()}`,
      state: "done",
      capability: request.capability,
      outputUrl: `data:audio/mpeg;base64,${btoa(binary)}`,
      charged: { unit: "allowance", amount: null, basis: `${text.length} characters`, quoted: false },
    };
  },

  async poll(_auth: Authorization, submitted: Submitted): Promise<Polled> {
    // `submit` already finished it.
    return { state: "done", outputUrl: submitted.outputUrl, outputMime: "audio/mpeg" };
  },

  classify(status: number, body: unknown): Verdict {
    const said = typeof body === "string"
      ? body
      : typeof (body as { detail?: unknown })?.detail === "string"
      ? String((body as { detail: string }).detail)
      : JSON.stringify(body ?? "");
    const words = said.toLowerCase();
    const detail = said.slice(0, 300);

    if (status === 401 || status === 403 || words.includes("invalid_api_key")) {
      return { code: "bad_key", retryable: false, tryAnotherModel: false, tryAnotherProvider: true, detail };
    }
    // Out of characters for the month, or the plan's limit: not worth a retry.
    if (status === 402 || words.includes("quota_exceeded") || words.includes("character limit")) {
      return { code: "no_credits", retryable: false, tryAnotherModel: false, tryAnotherProvider: true, detail };
    }
    if (status === 429) {
      return { code: "rate_limited", retryable: true, tryAnotherModel: false, tryAnotherProvider: true, detail };
    }
    if (words.includes("timeout") || status === 504) {
      return { code: "provider_down", retryable: true, tryAnotherModel: false, tryAnotherProvider: true, detail };
    }
    return unknownVerdict(status, detail);
  },
};
