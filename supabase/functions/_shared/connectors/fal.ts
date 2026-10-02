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
 * tables below with `quoted: false` -- which the picker renders differently
 * from a number the provider committed to. When these drift, they drift in one
 * place.
 *
 * 29 SEP 2026 -- THE WHOLE FILE WAS CHECKED AGAINST fal's OWN SCHEMAS.
 * Netro, looking at the model card for "Animate this image": it did not offer
 * the size, the pixels or the voiceover, and what he typed ("480 4s") changed
 * nothing. Reading every endpoint's OpenAPI schema
 * (https://fal.ai/api/openapi/queue/openapi.json?endpoint_id=<id>) found why:
 *
 *   - `aspect` and `count` were never sent by the app AND the video body always
 *     set `aspect_ratio` to a default, so every picture and video was 9:16
 *     whatever was chosen;
 *   - Kling has no `resolution` field and Veo spells its durations "4s", "6s",
 *     "8s" -- this adapter sent `resolution` to Kling and "8" to Veo, both of
 *     which are 422s that `classify` then reported as "the provider refused
 *     that prompt";
 *   - only Wan had a picture-to-video endpoint listed, so "Animate" offered
 *     five models and four of them threw "cannot work from a picture";
 *   - no image model was given the reference picture at all: the text-to-image
 *     endpoints ignore it, so "use this picture" produced something unrelated;
 *   - three of the prices were under what fal charges (Veo 3.1 Fast with sound
 *     is $0.15 a second, not $0.10; Kling 2.1 Master is $1.40 for five seconds,
 *     not $1.12; Nano Banana 2 is $0.08 an image, not $0.06) -- money lost on
 *     every one, shown to the customer as the price.
 *
 * So each model below declares exactly what its endpoints accept, and `submit`
 * builds the body from that declaration instead of from a shared guess.
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

// ------------------------------------------------------------------ video

/**
 * What we offer, and what each second costs us.
 *
 * Prices read off fal's own model pages on 29 Sep 2026. `perSecond` is OUR
 * cost, in dollars -- the number the plan budget is spent against, never the
 * number shown to a customer.
 *
 * Ordered cheapest first, which is also `rank`: "best available" should mean
 * the cheapest thing that can do the job, not the most expensive.
 */
interface Entry {
  /** The text-to-video endpoint. */
  id: string;
  label: string;
  about: string;
  /** What we charge as a multiple of what fal charges us. Absent is 1: the
   *  everyday models are sold at cost and the plan itself carries the margin;
   *  quality models carry 1.25 and the flagships 1.5. See `billable`. */
  markup?: number;
  /** Dollars per second of output, by resolution. 🔴 Not one number: Wan is
   *  $0.05 at 480p, $0.10 at 720p and $0.15 at 1080p, and quoting the cheapest
   *  while submitting at the model's own default -- which is 1080p -- would
   *  have shown a price three times under what it charged. */
  perSecond: Record<string, number>;
  /** The same ladder with sound switched off, where the provider charges
   *  less for it. 🔴 Veo 3.1 is $0.40 a second with audio and $0.20 without
   *  -- HALF -- so "no sound" is not a preference, it is the single biggest
   *  cost lever on the most expensive model we offer. */
  perSecondSilent?: Record<string, number>;
  /** Lengths we offer, in seconds. A subset of what the endpoint accepts where
   *  it accepts many (Kling 3 takes every second from 3 to 15; a menu of
   *  thirteen is not a choice). */
  durations: number[];
  /** 🔴 How the schema spells a length: "5" (Kling) or "8s" (Veo). Sending
   *  the other spelling is a 422 and the job never starts. */
  durationSuffix: boolean;
  /** ...or as a bare integer (MiniMax H3, Wan 3.0). */
  durationInt?: boolean;
  /** Resolutions the endpoint accepts. Absent when it has no such field at all
   *  (Kling): sending one anyway is a 422. Always written lower-case here;
   *  `resolutionUpper` says how the endpoint wants it spelled. */
  resolutions?: string[];
  /** MiniMax spells them "768P". */
  resolutionUpper?: boolean;
  /** What we price at, and ask for unless told otherwise. Never left to the
   *  model: fal defaults Wan to 1080p and 16:9, and 16:9 is the wrong shape for
   *  every video this app makes. */
  resolution: string;
  /** Aspect ratios the TEXT-to-video endpoint accepts. */
  aspects: string[];
  /** The separate endpoint that takes a starting picture. 🔴 A text-to-video
   *  endpoint does not accept one and does not complain -- it ignores it and
   *  makes something unrelated, which is worse than refusing. */
  imageEndpoint: string;
  /** What that endpoint calls the starting picture. Most say `image_url`;
   *  Kling 3 and Wan 3 say `start_image_url`. */
  startField?: string;
  /** Whether that endpoint takes an aspect ratio of its own. Veo's does
   *  ("auto" follows the picture); the others take their shape from the
   *  picture and reject or ignore the field. */
  pictureAspect: boolean;
  /** Makes its own sound. */
  audio: boolean;
  /** What the switch for it is called: `generate_audio` for nearly everyone,
   *  `audio` for Wan 3. */
  audioField?: string;
  /** False when sound is always on and there is nothing to turn off (MiniMax
   *  H3): the app then shows no sound button rather than one that does nothing. */
  audioSwitch?: boolean;
  /** Takes `negative_prompt`. */
  negative: boolean;
  /** The picture-to-video endpoint also takes a LAST frame. */
  endFrame?: boolean;
  /** ...and what it calls it: `tail_image_url` (Kling 2.5) or `end_image_url`. */
  endField?: string;
  /** Takes an `audio_url` to drive the video with -- a voice or a track. */
  audioInput?: boolean;
  /** Fields a schema REQUIRES and that never change (MiniMax:
   *  `prompt_expansion_mode`). */
  extra?: Record<string, unknown>;
  /** The lowest plan tier that may use it: 1 Pro, 2 Max, 3 Ultra. Enforced by
   *  `chargeForGeneration` (0077). Absent means any paid plan. */
  minTier?: number;
}

/**
 * What we offer. Rewritten 29 Sep 2026, evening, after Netro: "there is no good
 * models honestly now, we need the most popular and good ones."
 *
 * Chosen from fal's live catalogue that day (`api.fal.ai/v1/models`, 136 active
 * text-to-video endpoints) and cross-checked against the arena rankings: Sora 2
 * was withdrawn on 24 Sep and is not on fal at all; MiniMax H3 Max (post-trained
 * by fal, ranked first for quality) and Seedance 2.x lead; Kling 3.0 and Veo 3.1
 * are what people ask for by name; Wan 3.0 is the cheap everyday one.
 *
 * Every price is the HIGHER of fal's own pricing API and the maker's published
 * rate, at the resolution actually asked for. Some are launch prices that will
 * end (H3 Max is $0.025 a second on fal today and $0.08 at MiniMax), and
 * charging the low number now would mean a loss the day it changes.
 *
 * Ordered cheapest first, which is also `rank`.
 */
const CATALOGUE: Entry[] = [
  {
    id: "minimax/h3-max-turbo/text-to-video",
    label: "MiniMax H3 Max Turbo",
    about: "The same look as H3 Max, twice as fast. Sound included.",
    perSecond: { "480p": 0.025, "768p": 0.04, "1080p": 0.07 },
    durations: [5, 8, 10, 15],
    durationSuffix: false,
    durationInt: true,
    resolutions: ["480p", "768p", "1080p"],
    resolutionUpper: true,
    resolution: "768p",
    aspects: ["9:16", "1:1", "16:9"],
    imageEndpoint: "minimax/h3-max-turbo/image-to-video",
    pictureAspect: false,
    audio: true,
    audioSwitch: false,
    negative: false,
    endFrame: true,
    endField: "end_image_url",
    extra: { prompt_expansion_mode: "balanced" },
  },
  {
    id: "alibaba/wan-3.0/text-to-video",
    label: "Wan 3.0",
    about: "Alibaba's newest. Sharp and cheap, with sound. The everyday choice.",
    perSecond: { "480p": 0.05, "720p": 0.10, "1080p": 0.15 },
    durations: [5, 10],
    durationSuffix: false,
    durationInt: true,
    resolutions: ["480p", "720p", "1080p"],
    resolution: "720p",
    aspects: ["9:16", "1:1", "16:9"],
    imageEndpoint: "alibaba/wan-3.0/image-to-video",
    startField: "start_image_url",
    pictureAspect: false,
    audio: true,
    audioField: "audio",
    negative: false,
    endFrame: true,
    endField: "end_image_url",
  },
  {
    id: "fal-ai/veo3.1/lite",
    label: "Google Veo 3.1 Lite",
    about: "Google's Veo at a fraction of the price, with sound.",
    perSecond: { "720p": 0.05, "1080p": 0.08 },
    durations: [4, 6, 8],
    durationSuffix: true,
    resolutions: ["720p", "1080p"],
    resolution: "720p",
    aspects: ["9:16", "16:9"],
    imageEndpoint: "fal-ai/veo3.1/lite/image-to-video",
    pictureAspect: true,
    audio: true,
    negative: true,
  },
  {
    id: "minimax/h3-max/text-to-video",
    label: "MiniMax H3 Max",
    markup: 1.25,
    about: "Ranked first for quality and prompt-following. Sharp faces, sound included.",
    perSecond: { "480p": 0.05, "768p": 0.08, "1080p": 0.14 },
    durations: [5, 8, 10, 15],
    durationSuffix: false,
    durationInt: true,
    resolutions: ["480p", "768p", "1080p"],
    resolutionUpper: true,
    resolution: "768p",
    aspects: ["9:16", "1:1", "16:9"],
    imageEndpoint: "minimax/h3-max/image-to-video",
    pictureAspect: false,
    audio: true,
    audioSwitch: false,
    negative: false,
    endFrame: true,
    endField: "end_image_url",
    extra: { prompt_expansion_mode: "balanced" },
  },
  {
    id: "fal-ai/kling-video/v2.5-turbo/pro/text-to-video",
    label: "Kling 2.5 Turbo Pro",
    about: "Steady motion and faces that hold together. Silent.",
    perSecond: { "720p": 0.07 },
    durations: [5, 10],
    durationSuffix: false,
    resolution: "720p",
    aspects: ["9:16", "1:1", "16:9"],
    imageEndpoint: "fal-ai/kling-video/v2.5-turbo/pro/image-to-video",
    pictureAspect: false,
    audio: false,
    negative: true,
    endFrame: true,
    endField: "tail_image_url",
  },
  {
    id: "fal-ai/veo3.1/fast",
    label: "Google Veo 3.1 Fast",
    markup: 1.25,
    about: "Realistic, follows the prompt closely, makes its own sound.",
    perSecond: { "720p": 0.15, "1080p": 0.15, "4k": 0.35 },
    perSecondSilent: { "720p": 0.10, "1080p": 0.10, "4k": 0.30 },
    durations: [4, 6, 8],
    durationSuffix: true,
    resolutions: ["720p", "1080p", "4k"],
    resolution: "720p",
    aspects: ["9:16", "16:9"],
    imageEndpoint: "fal-ai/veo3.1/fast/image-to-video",
    pictureAspect: true,
    audio: true,
    negative: true,
  },
  {
    id: "fal-ai/kling-video/v3/pro/text-to-video",
    label: "Kling 3.0 Pro",
    markup: 1.25,
    about: "Kling's newest. Steady motion, sharp faces, native sound and lip-sync.",
    perSecond: { "720p": 0.168 },
    perSecondSilent: { "720p": 0.112 },
    durations: [5, 8, 10, 15],
    durationSuffix: false,
    resolution: "720p",
    aspects: ["9:16", "1:1", "16:9"],
    imageEndpoint: "fal-ai/kling-video/v3/pro/image-to-video",
    startField: "start_image_url",
    pictureAspect: false,
    audio: true,
    negative: true,
    endFrame: true,
    endField: "end_image_url",
  },
  {
    id: "bytedance/seedance-2.0/fast/text-to-video",
    label: "Seedance 2.0 Fast",
    markup: 1.25,
    about: "ByteDance. Cinematic motion with sound, quick to make.",
    // Billed by the token, not the second: width x height x 24 x seconds / 1024
    // tokens at $0.0112 per thousand. These are that, per second, rounded up.
    perSecond: { "480p": 0.11, "720p": 0.25 },
    durations: [4, 5, 8, 10, 15],
    durationSuffix: false,
    resolutions: ["480p", "720p"],
    resolution: "720p",
    aspects: ["9:16", "1:1", "16:9"],
    imageEndpoint: "bytedance/seedance-2.0/fast/image-to-video",
    pictureAspect: false,
    audio: true,
    negative: false,
    endFrame: true,
    endField: "end_image_url",
  },
  {
    id: "fal-ai/veo3.1",
    label: "Google Veo 3.1",
    markup: 1.5,
    about: "The best of them, with audio. Costs what that implies.",
    perSecond: { "720p": 0.40, "1080p": 0.40, "4k": 0.60 },
    perSecondSilent: { "720p": 0.20, "1080p": 0.20, "4k": 0.40 },
    durations: [4, 6, 8],
    durationSuffix: true,
    resolutions: ["720p", "1080p", "4k"],
    resolution: "720p",
    aspects: ["9:16", "16:9"],
    imageEndpoint: "fal-ai/veo3.1/image-to-video",
    pictureAspect: true,
    audio: true,
    negative: true,
    minTier: 2,
  },
  {
    id: "bytedance/seedance-2.5/text-to-video",
    label: "Seedance 2.5",
    markup: 1.5,
    about: "ByteDance's best. One shot up to 30 seconds, up to 1080p, with sound.",
    // $0.0214 per thousand tokens -- see Seedance 2.0 Fast above.
    perSecond: { "480p": 0.21, "720p": 0.47, "1080p": 1.05 },
    durations: [5, 10, 15, 20, 30],
    durationSuffix: false,
    resolutions: ["480p", "720p", "1080p"],
    resolution: "720p",
    aspects: ["9:16", "1:1", "16:9"],
    imageEndpoint: "bytedance/seedance-2.5/image-to-video",
    pictureAspect: false,
    audio: true,
    negative: false,
    endFrame: true,
    endField: "end_image_url",
    minTier: 2,
  },
];

function entry(id: string) {
  return CATALOGUE.find((model) => model.id === id);
}

/** What a second costs at the resolution actually being asked for. */
function rate(model: Entry, resolution: string, silent = false): number {
  const ladder = silent && model.perSecondSilent ? model.perSecondSilent : model.perSecond;
  return ladder[resolution] ?? ladder[model.resolution] ?? Object.values(ladder)[0];
}

/** One credit is a cent at the rate card's base price. The same number as
 *  `CREDIT_USD` in `_shared/credits.ts` (a test holds them equal); it is not
 *  imported because credits.ts imports the router, which imports this. */
const CREDIT_USD = 0.01;

/** Pictures are sold at a quarter over what they cost us. */
const IMAGE_MARKUP = 1.25;

/**
 * The rate card, in one place. Netro, 2 Oct 2026: show people ordinary credits,
 * not a money-looking number, and let each model carry the margin it should.
 *
 * `usd` is what fal charges us. The answer is what the customer is charged,
 * as dollars in WHOLE credits -- rounded up, never to nothing -- so the phone
 * (`amount * 100`) and the server (`amount / CREDIT_USD`) cannot land one
 * credit apart on a half. `ours` keeps the real cost for the books.
 *
 * The 1e-6 keeps 35.00000000000001 from becoming 36.
 */
function billable(usd: number, markup = 1): { amount: number; ours: number } {
  const credits = Math.max(1, Math.ceil(usd * markup * 100 - 1e-6));
  return { amount: Number((credits * CREDIT_USD).toFixed(2)), ours: Number(usd.toFixed(4)) };
}

/** Whether this request asked for a silent video. */
function isSilent(request: SubmitRequest): boolean {
  // 🔴 Both shapes. A generation carries a real boolean; a QUOTE carries the
  // string "false", because `quote` keeps only top-level strings and numbers
  // out of the settings it is given. Checking one shape only is how the price
  // shown and the price charged drift apart.
  const said = request.options?.generate_audio ?? request.options?.audio;
  return said === false || said === "false";
}

/** The resolution this request will run at: what was asked for if the model
 *  offers it, else the model's own default. Never fal's default, which is the
 *  most expensive one it has. */
function resolutionFor(model: Entry, request: SubmitRequest): string {
  const asked = String(request.options?.resolution ?? "").toLowerCase();
  return model.perSecond[asked] ? asked : model.resolution;
}

/** The length the model will really make: what was asked for, moved to the
 *  nearest one it offers. "6 seconds" on Wan used to go out as "6" and come
 *  back a 422, because Wan only makes 5 and 10. */
function lengthFor(model: Entry, request: SubmitRequest): number {
  const asked = Number(request.options?.duration);
  if (!Number.isFinite(asked) || asked <= 0) return model.durations[0];
  return model.durations.reduce(
    (best, candidate) => Math.abs(candidate - asked) < Math.abs(best - asked) ? candidate : best,
    model.durations[0],
  );
}

/** The shape asked for, from whichever name the caller used: the app's own
 *  words say `aspect`, the chat router's say `aspect_ratio`. */
function askedAspect(request: SubmitRequest): string | undefined {
  const said = request.options?.aspect ?? request.options?.aspect_ratio;
  return typeof said === "string" && said ? said : undefined;
}

/** One of `allowed`: the one asked for if it is there, else vertical, else the
 *  first. This app makes videos for a phone. */
function pick(allowed: string[], asked: string | undefined): string {
  if (asked && allowed.includes(asked)) return asked;
  return allowed.includes("9:16") ? "9:16" : allowed[0];
}

/** The body for one video job, field by field from what THIS endpoint declares.
 *  🔴 Never spread from `options`: the schema rejects unknown keys, and
 *  `options` carries this app's own words -- voiceover, captions, aspect --
 *  which are instructions for the writer, not for fal. */
function videoInput(
  model: Entry,
  request: SubmitRequest,
  picture: string | undefined,
  tail: string | undefined,
): Record<string, unknown> {
  const length = lengthFor(model, request);
  const input: Record<string, unknown> = {
    prompt: request.prompt,
    // Three spellings of the same number: 8 (MiniMax, Wan 3), "5" (Kling,
    // Seedance) and "8s" (Veo). Each of the others is a 422.
    duration: model.durationInt ? length : model.durationSuffix ? `${length}s` : String(length),
    ...(model.extra ?? {}),
  };
  if (model.resolutions) {
    const wanted = resolutionFor(model, request);
    input.resolution = model.resolutionUpper ? wanted.toUpperCase() : wanted;
  }

  if (picture) {
    input[model.startField ?? "image_url"] = picture;
    // Picture-to-video takes its shape from the picture. Veo alone has a field
    // for it, and "auto" is the answer that keeps the picture's own frame.
    if (model.pictureAspect) input.aspect_ratio = "auto";
    if (tail && model.endFrame) input[model.endField ?? "tail_image_url"] = tail;
  } else {
    input.aspect_ratio = pick(model.aspects, askedAspect(request));
  }

  // Sound, where the model makes its own and lets it be switched. Sent
  // explicitly rather than left to the model default, because the default is
  // ON and that is the expensive one. MiniMax H3 has no switch -- its sound is
  // always there -- so there is nothing to send.
  if (model.audio && model.audioSwitch !== false) {
    input[model.audioField ?? "generate_audio"] = !isSilent(request);
  }

  const negative = request.options?.negative_prompt;
  if (model.negative && typeof negative === "string" && negative.trim()) {
    input.negative_prompt = negative.trim();
  }

  const voice = request.options?.audio_url;
  if (model.audioInput && typeof voice === "string" && voice) input.audio_url = voice;

  return input;
}

// ------------------------------------------------------------------ images

/**
 * The image models, and how each one wants to be told the shape.
 *
 * Abel, 26 Sep 2026: "there is no model for the image generator". True -- this
 * adapter only ever declared video, so the image picker was empty.
 *
 * 🔴 THEY DO NOT AGREE ON FIELD NAMES, which is the same trap `duration` was.
 * Checked against each model's own OpenAPI schema rather than assumed: the
 * Nano Bananas and Kontext take `aspect_ratio: "9:16"`, while FLUX, Seedream,
 * Qwen and Recraft take `image_size: "portrait_16_9"` (or a {width, height}).
 * Sending the wrong one is a 422, or worse, a silently square picture.
 *
 * And a picture to work FROM is a different endpoint again: the `/edit` twin of
 * the model, which takes `image_urls` (Nano Banana, Seedream) or `image_url`
 * (Qwen). The text-to-image endpoint ignores the field without complaint, which
 * is why "use this picture" used to make something unrelated.
 *
 * Prices are per image from fal's pricing pages, so `quoted: false`.
 */
interface ImageEntry {
  id: string;
  label: string;
  about: string;
  /** Dollars per image at the default tier and size. */
  each: number;
  /** Which field this model names the shape with. */
  shape: "aspect_ratio" | "image_size";
  /** What we offer, and every one of these is accepted by the endpoint. */
  aspects: string[];
  /** Quality tiers and what each costs relative to the default -- "2K" on Nano
   *  Banana, "Medium" on GPT Image, "Balanced" on Ideogram. The keys are the
   *  names people see; `tierValues` says how the endpoint spells each. */
  tiers?: Record<string, number>;
  tier?: string;
  /** The field the tier travels in: `resolution` for most, `quality` for GPT
   *  Image, `rendering_speed` for Ideogram. */
  tierField?: string;
  tierValues?: Record<string, string>;
  /** The endpoint that takes reference pictures, and the field it wants. */
  edit?: { id: string; field: "image_urls" | "image_url" };
  /** Lowest plan tier that may use it, when it is not the free one. */
  minTier?: number;
}

const FRAMES = ["9:16", "4:5", "1:1", "16:9"];
/** The shapes the models that only take presets can make. */
const PRESET_FRAMES = ["9:16", "3:4", "1:1", "4:3", "16:9"];

/**
 * Rewritten 29 Sep 2026, evening, with the videos: GPT Image 2 is first in every
 * blind vote (and OpenAI moved consumers on to 2.5 on 8 Sep), Nano Banana Pro
 * and Seedream 5 are the other two people name, Ideogram V4 is the one for words
 * in pictures, and Grok Imagine and Qwen 3 are the cheap ones. Prices are the
 * higher of fal's pricing API and the maker's own, at the tier asked for.
 */
const IMAGES: ImageEntry[] = [
  {
    id: "fal-ai/flux/schnell",
    label: "FLUX Schnell",
    about: "The quick one. Good for trying a composition.",
    each: 0.003,
    shape: "image_size",
    aspects: FRAMES,
  },
  {
    id: "alibaba/qwen-image-3/text-to-image",
    label: "Qwen Image 3",
    about: "Cheap and clean, strong with text in the picture.",
    each: 0.03,
    shape: "image_size",
    aspects: FRAMES,
    edit: { id: "alibaba/qwen-image-3/edit", field: "image_urls" },
  },
  {
    id: "xai/grok-imagine-image/v2.0/text-to-image",
    label: "Grok Imagine Image 2",
    about: "xAI's. Fast, bold and inexpensive.",
    each: 0.03,
    shape: "aspect_ratio",
    aspects: PRESET_FRAMES,
    tiers: { "1K": 1, "2K": 2 },
    tier: "1K",
    tierValues: { "1K": "1k", "2K": "2k" },
    edit: { id: "xai/grok-imagine-image/v2.0/edit", field: "image_urls" },
  },
  {
    id: "fal-ai/nano-banana",
    label: "Google Nano Banana",
    about: "Quick, high-quality generation and editing.",
    each: 0.039,
    shape: "aspect_ratio",
    aspects: FRAMES,
    edit: { id: "fal-ai/nano-banana/edit", field: "image_urls" },
  },
  {
    id: "ideogram/v4",
    label: "Ideogram V4",
    about: "The best with words in pictures: posters, covers, thumbnails.",
    each: 0.06,
    shape: "image_size",
    aspects: PRESET_FRAMES,
    tiers: { Fast: 0.5, Balanced: 1, Quality: 1.5 },
    tier: "Balanced",
    tierField: "rendering_speed",
    tierValues: { Fast: "TURBO", Balanced: "BALANCED", Quality: "QUALITY" },
  },
  {
    id: "bytedance/seedream/v5/pro/text-to-image",
    label: "Seedream 5 Pro",
    about: "ByteDance's. Photographic, great with people and products.",
    each: 0.07,
    shape: "image_size",
    aspects: FRAMES,
    edit: { id: "bytedance/seedream/v5/pro/edit", field: "image_urls" },
  },
  {
    id: "fal-ai/nano-banana-2",
    label: "Google Nano Banana 2",
    about: "Knows the world, precise text, fast.",
    each: 0.08,
    shape: "aspect_ratio",
    aspects: FRAMES,
    tiers: { "0.5K": 0.75, "1K": 1, "2K": 1.5, "4K": 2 },
    tier: "1K",
    edit: { id: "fal-ai/nano-banana-2/edit", field: "image_urls" },
  },
  {
    id: "openai/gpt-image-2",
    label: "GPT Image 2",
    about: "OpenAI's newest. The most accurate, and the best with text.",
    // 🔴 Medium, not fal's default of High: High costs about $0.21 a picture
    // and is what its average call costs on fal. Medium is $0.07, and Low is
    // $0.03 -- so a person chooses to pay for High rather than paying for it
    // without knowing.
    each: 0.07,
    shape: "image_size",
    aspects: PRESET_FRAMES,
    tiers: { Low: 0.4, Medium: 1, High: 3 },
    tier: "Medium",
    tierField: "quality",
    tierValues: { Low: "low", Medium: "medium", High: "high" },
    edit: { id: "openai/gpt-image-2/edit", field: "image_urls" },
  },
  {
    id: "fal-ai/nano-banana-pro",
    label: "Google Nano Banana Pro",
    about: "Studio quality, legible text, very consistent.",
    each: 0.15,
    shape: "aspect_ratio",
    aspects: FRAMES,
    tiers: { "1K": 1, "2K": 1, "4K": 2 },
    tier: "1K",
    edit: { id: "fal-ai/nano-banana-pro/edit", field: "image_urls" },
  },
];

/** fal's own names for the frames it has a preset for. */
const IMAGE_SIZES: Record<string, string> = {
  "9:16": "portrait_16_9",
  "3:4": "portrait_4_3",
  "1:1": "square_hd",
  "4:3": "landscape_4_3",
  "16:9": "landscape_16_9",
};

/** A `image_size` for any shape: fal's preset when it has one, else a
 *  {width, height} of about a megapixel, in multiples of 16 -- which is what
 *  "4:5" needs, since fal has no preset for it. */
function sizeFor(aspect: string): string | { width: number; height: number } {
  const preset = IMAGE_SIZES[aspect];
  if (preset) return preset;
  const [w, h] = aspect.split(":").map(Number);
  if (!(w > 0 && h > 0)) return IMAGE_SIZES["9:16"];
  const width = Math.max(512, Math.round(Math.sqrt(1_000_000 * (w / h)) / 16) * 16);
  const height = Math.max(512, Math.round(Math.sqrt(1_000_000 * (h / w)) / 16) * 16);
  return { width, height };
}

function imageEntry(id: string) {
  return IMAGES.find((model) => model.id === id);
}

/** The tier this request will run at, for the models that have tiers. */
function tierFor(model: ImageEntry, request: SubmitRequest): string | undefined {
  if (!model.tiers) return undefined;
  // Whatever case it comes in: the app sends the names it was given, and a
  // hand-typed "2k" arrives lower-case.
  const asked = String(request.options?.resolution ?? "").toLowerCase();
  return Object.keys(model.tiers).find((name) => name.toLowerCase() === asked) ?? model.tier;
}

/** What one request costs: the model's price, at its tier, times how many. */
function imageCost(model: ImageEntry, request: SubmitRequest): { amount: number; count: number } {
  const asked = Number(request.options?.count ?? 1);
  const count = Math.max(1, Math.min(4, Math.round(Number.isFinite(asked) ? asked : 1)));
  const tier = tierFor(model, request);
  const multiplier = tier && model.tiers ? model.tiers[tier] : 1;
  return { amount: Number((model.each * multiplier * count).toFixed(4)), count };
}

// ------------------------------------------------------------------ plumbing

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

/** A refusal we raise ourselves, before fal is asked -- in the shape `classify`
 *  would have given it, so the router can move on to another model. */
function cannot(message: string, detail: string): Error {
  return Object.assign(new Error(message), {
    status: 422,
    verdict: {
      code: "refused" as const,
      retryable: false,
      tryAnotherModel: true,
      tryAnotherProvider: false,
      detail,
    },
  });
}

/**
 * One picture. Separate from `submit` because almost nothing is shared: no
 * duration, no resolution ladder, no image-to-video endpoint, and a shape
 * field whose NAME depends on the model.
 */
async function makePicture(auth: Authorization, request: SubmitRequest): Promise<Submitted> {
  const model = imageEntry(request.model);
  const aspect = pick(model?.aspects ?? FRAMES, askedAspect(request));

  const input: Record<string, unknown> = { prompt: request.prompt };
  if (model?.shape === "image_size") {
    input.image_size = sizeFor(aspect);
  } else {
    input.aspect_ratio = aspect;
  }
  // The tier goes in the field THIS model keeps it in, spelled its way:
  // `resolution: "2K"` for Nano Banana, `quality: "medium"` for GPT Image,
  // `rendering_speed: "BALANCED"` for Ideogram.
  const tier = model ? tierFor(model, request) : undefined;
  if (tier && model) input[model.tierField ?? "resolution"] = model.tierValues?.[tier] ?? tier;

  // How many at once. Every one of these bills per image, so the count is the
  // bill.
  const { count } = model ? imageCost(model, request) : { count: 1 };
  if (count > 1) input.num_images = count;

  // 🔴 A picture to work from means the model's EDIT endpoint. The plain one
  // ignores the field and makes something unrelated, and the result looks
  // fine -- the worst kind of failure, because nobody is told.
  const pictures = (request.references ?? [])
    .filter((reference) => reference.kind === "image" && reference.url)
    .map((reference) => reference.url as string);
  let endpoint = request.model;
  if (pictures.length > 0) {
    if (!model?.edit) {
      throw cannot(
        `${model?.label ?? request.model} cannot work from a picture`,
        "that model makes pictures from words only",
      );
    }
    endpoint = model.edit.id;
    if (model.edit.field === "image_urls") {
      input.image_urls = pictures.slice(0, 4);
    } else {
      input.image_url = pictures[0];
    }
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
  if (typeof ref !== "string") throw new Error("fal accepted the picture but named no request id");

  return {
    ref,
    statusUrl: typeof body?.status_url === "string"
      ? body.status_url
      : `${QUEUE}/${endpoint}/requests/${ref}/status`,
    state: "queued",
    capability: request.capability,
    charged: {
      unit: "usd",
      ...(model ? billable(imageCost(model, request).amount, IMAGE_MARKUP) : { amount: 0 }),
      basis: count > 1 ? `${count} images` : "1 image",
      quoted: false,
    },
  };
}

// ------------------------------------------------------------------ discovery

/**
 * Every model we offer, described the way the app reads a model: what it makes,
 * what it costs, and -- new on 29 Sep -- exactly which knobs it has, so the card
 * and the composer show the ones that apply and never a dead one.
 *
 * Pure, and exported, so the catalogue can be re-recorded without a key
 * (`record_discovery` takes this list as it is).
 */
export function describeCatalogue(): ModelDescriptor[] {
  const videos: ModelDescriptor[] = CATALOGUE.map((model, index) => ({
    capability: "video_generation",
    external_id: model.id,
    label: model.label,
    metadata: {
      description: model.about,
      cost: {
        unit: "per_second",
        amount: Number((rate(model, model.resolution) * (model.markup ?? 1)).toFixed(4)),
        basis: "per second of finished video",
        quoted: false,
      } satisfies Cost,
      constraints: {
        durations: model.durations,
        aspectRatios: model.aspects,
        resolutions: model.resolutions ?? [],
        notes: model.audio ? undefined : ["No sound"],
        defaults: { duration: model.durations[0], resolution: model.resolution },
        // What it can do, for the card and the bar to show only what applies.
        audio: model.audio,
        // Whether sound can be switched off. MiniMax H3's cannot: it is always
        // there, so the app shows no sound button rather than a dead one.
        audioSwitch: model.audio && model.audioSwitch !== false,
        takesPicture: true,
        endFrame: model.endFrame === true,
        negativePrompt: model.negative,
        // Whether a picture leaves the shape to be chosen. Where it does not,
        // the shape is the picture's own and the size control is not offered.
        pictureAspect: model.pictureAspect,
        // The plan it needs: 2 is Max. Also on the model itself, where the
        // server reads it (`chargeForGeneration`).
        ...(model.minTier ? { minTier: model.minTier } : {}),
      },
      ...(model.minTier ? { minTier: model.minTier } : {}),
      // Read by `suits`: a model that starts from a picture is one that can be
      // asked to animate one.
      medias: [{ roles: ["start_image"] }],
      frames: true,
    },
    rank: index,
  }));

  const pictures: ModelDescriptor[] = IMAGES.map((model, index) => ({
    capability: "image_generation",
    external_id: model.id,
    label: model.label,
    metadata: {
      description: model.about,
      cost: {
        unit: "per_image",
        amount: Number((model.each * IMAGE_MARKUP).toFixed(4)),
        basis: "per image",
        quoted: false,
      } satisfies Cost,
      constraints: {
        aspectRatios: model.aspects,
        resolutions: model.tiers ? Object.keys(model.tiers) : [],
        defaults: model.tier ? { resolution: model.tier } : {},
        audio: false,
        audioSwitch: false,
        takesPicture: model.edit !== undefined,
        endFrame: false,
        negativePrompt: false,
        ...(model.minTier ? { minTier: model.minTier } : {}),
      },
      ...(model.minTier ? { minTier: model.minTier } : {}),
      ...(model.edit ? { medias: [{ roles: ["image"] }] } : {}),
      frames: false,
    },
    rank: index,
  }));

  return [...videos, ...pictures];
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
    // request id simply does not exist, which is the answer we want. An EMPTY
    // BALANCE is also a 403 (`User is locked. Reason: Exhausted balance.`), and
    // the key is fine then -- refusing it here would expire a working
    // connection because somebody had not topped up.
    const empty = JSON.stringify(body ?? "").toLowerCase().includes("exhausted balance");
    if ((status === 401 || status === 403) && !empty) {
      throw new Error(`fal refused the key: ${JSON.stringify(body).slice(0, 160)}`);
    }

    return { accountLabel: "fal.ai", externalAccountId: null, models: describeCatalogue() };
  },

  async submit(auth: Authorization, request: SubmitRequest): Promise<Submitted> {
    // Pictures first: a different catalogue, a different body, and no
    // duration at all.
    if (request.capability === "image_generation") {
      return await makePicture(auth, request);
    }

    const model = entry(request.model);
    if (!model) {
      throw cannot(`${request.model} is not a model this generator offers`, "unknown model");
    }

    const stills = (request.references ?? [])
      .filter((reference) => reference.kind === "image" && reference.url)
      .map((reference) => reference.url as string);
    const picture = stills[0];
    const tail = stills[1];

    // A picture means the model's picture-to-video endpoint, not an extra
    // field on the text one.
    const endpoint = picture ? model.imageEndpoint : request.model;
    const input = videoInput(model, request, picture, tail);
    const length = lengthFor(model, request);
    const resolution = resolutionFor(model, request);
    const silent = isSilent(request);

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
        ...billable(length * rate(model, resolution, silent), model.markup),
        basis: `${length}s of ${resolution}${silent && model.audio ? ", silent" : ""} at ${rate(model, resolution, silent)}/s`,
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

    // A video answers under `video`, a picture under `images[0]`. Asking for
    // the wrong one is how a poster frame once passed as a finished video --
    // so what was asked for decides what is looked for.
    const wanted = submitted.capability === "image_generation"
      ? (result.body?.images?.[0] ?? result.body?.image)
      : (result.body?.video ?? result.body?.videos?.[0]);
    const url = wanted?.url ?? result.body?.url;
    if (typeof url !== "string") {
      return {
        state: "failed",
        verdict: {
          code: "bad_output",
          retryable: false,
          tryAnotherModel: true,
          tryAnotherProvider: true,
          detail: `fal reported ${state} with nothing usable: ${JSON.stringify(result.body).slice(0, 200)}`,
        },
      };
    }

    return {
      state: "done",
      outputUrl: url,
      outputMime: typeof wanted?.content_type === "string"
        ? wanted.content_type
        : (submitted.capability === "image_generation" ? "image/jpeg" : "video/mp4"),
    };
  },

  /**
   * What this exact job costs us, from the published rate and the length asked
   * for. `quoted: false` because fal has no price-check call -- this is our
   * reading of their pricing page, and the picker says so.
   */
  quote(_auth: Authorization, request: SubmitRequest): Promise<Cost | null> {
    const picture = imageEntry(request.model);
    if (picture) {
      const { amount, count } = imageCost(picture, request);
      return Promise.resolve({
        unit: "usd",
        ...billable(amount, IMAGE_MARKUP),
        basis: count > 1 ? `${count} images` : "per image",
        quoted: false,
      });
    }

    const model = entry(request.model);
    if (!model) return Promise.resolve(null);
    const length = lengthFor(model, request);
    const resolution = resolutionFor(model, request);
    const silent = isSilent(request);
    const each = rate(model, resolution, silent);
    return Promise.resolve({
      unit: "usd",
      ...billable(length * each, model.markup),
      basis: `${length}s of ${resolution}${silent && model.audio ? ", silent" : ""} at ${each}/s`,
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

    // 🔴 An empty fal account answers 403, not 402: `{"detail":"User is locked.
    // Reason: Exhausted balance. Top up your balance at fal.ai/dashboard/billing."}`
    // on EVERY endpoint. Read as the 403 it looks like, that was `bad_key`, and
    // `routeSubmit` answers `bad_key` by marking the whole connection expired --
    // so on 29 Sep one empty balance turned the house generator off for everyone
    // and every later job said "nothing you've connected can make video", the
    // same words for a different failure. It is a balance, and a balance is
    // `no_credits`: nothing wrong with the key, nothing to reconnect.
    if (words.includes("exhausted balance") || words.includes("top up your balance")) {
      return {
        code: "no_credits",
        retryable: false,
        tryAnotherModel: false,
        tryAnotherProvider: true,
        detail: said.slice(0, 300),
      };
    }

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
