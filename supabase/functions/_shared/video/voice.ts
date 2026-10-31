import type { WordTiming } from "./types.ts";
import { wordsFromCharacters } from "./captions.ts";

/**
 * ElevenLabs text-to-speech with timing, so the captions and the scene cuts
 * come from what was actually said.
 *
 * `fetch` is injected so tests never spend credit. The response shape
 * (`audio_base64` + `alignment.characters / character_start_times_seconds /
 * character_end_times_seconds`) is ElevenLabs' `/with-timestamps` contract;
 * if a model returns no alignment the caller gets `words: []` and a reason,
 * never invented times.
 */
export interface SpeakRequest {
  apiKey: string;
  voiceId: string;
  text: string;
  /** e.g. eleven_multilingual_v2. Left to the caller: availability differs by plan. */
  model: string;
  /** 0.7 .. 1.2 */
  speed?: number;
  /** Plan-allowed container, e.g. mp3_44100_128. */
  outputFormat?: string;
  fetch?: typeof fetch;
}

export interface Spoken {
  audio: Uint8Array;
  mime: string;
  words: WordTiming[];
  /** Real length of the speech: the last word's end, or null without timing. */
  durationS: number | null;
  /** Characters billed, as sent. */
  characters: number;
  problem: string | null;
}

export class VoiceError extends Error {
  constructor(
    message: string,
    readonly status: number,
    /** Worth another try later (rate limit, upstream trouble). */
    readonly retryable: boolean,
  ) {
    super(message);
  }
}

export async function speak(r: SpeakRequest): Promise<Spoken> {
  const text = r.text.trim();
  if (!text) throw new VoiceError("nothing to say", 400, false);
  const format = r.outputFormat ?? "mp3_44100_128";
  const url = `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(r.voiceId)}/with-timestamps?output_format=${format}`;

  const res = await (r.fetch ?? fetch)(url, {
    method: "POST",
    headers: { "xi-api-key": r.apiKey, "content-type": "application/json" },
    body: JSON.stringify({
      text,
      model_id: r.model,
      ...(r.speed ? { voice_settings: { speed: Math.min(1.2, Math.max(0.7, r.speed)) } } : {}),
    }),
  });

  if (!res.ok) {
    // The provider's body can echo the request; keep a short reason only.
    const detail = (await res.text().catch(() => "")).slice(0, 200);
    throw new VoiceError(`voice provider ${res.status}: ${detail}`, res.status, res.status === 429 || res.status >= 500);
  }

  const body = await res.json() as {
    audio_base64?: string;
    alignment?: {
      characters?: string[];
      character_start_times_seconds?: number[];
      character_end_times_seconds?: number[];
    } | null;
  };
  if (!body.audio_base64) throw new VoiceError("the voice provider returned no audio", 502, true);
  const audio = Uint8Array.from(atob(body.audio_base64), (c) => c.charCodeAt(0));

  const a = body.alignment;
  const words = a?.characters && a.character_start_times_seconds && a.character_end_times_seconds
    ? wordsFromCharacters(a.characters, a.character_start_times_seconds, a.character_end_times_seconds)
    : [];
  return {
    audio,
    mime: format.startsWith("mp3") ? "audio/mpeg" : "audio/wav",
    words,
    durationS: words.length ? words[words.length - 1]!.endS : null,
    characters: text.length,
    problem: words.length ? null : "the provider returned no word timing for this model",
  };
}
