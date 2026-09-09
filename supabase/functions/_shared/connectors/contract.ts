/**
 * What every provider has to look like from the outside.
 *
 * The rule this file exists to enforce: nothing above this line may know which
 * provider it is talking to. `generate.ts` currently does the opposite -- it
 * imports Higgsfield directly -- and every comment in it claims otherwise. Add
 * image generation to that design and you hardcode a second vendor in the same
 * place; add a second video provider and the caller has to know both.
 *
 * So an adapter answers four questions and nothing else:
 *
 *   discover  what can this connection actually do
 *   submit    start one unit of work, return immediately
 *   poll      is it done, and where is the output
 *   classify  what does this failure MEAN, in shared words
 *
 * `classify` is the one people leave out and it is the one that makes recovery
 * possible. Without it every caller ends up matching on provider prose -- which
 * is how `model_not_found` reached a customer's home screen -- and a second
 * provider means a second set of string matches in the wrong layer.
 *
 * Nothing here is async-optional: every provider worth connecting is a queue,
 * so submit-then-poll is the shape, and a provider that happens to answer
 * instantly simply returns a terminal state from `submit`.
 */

/** The closed vocabulary from `capabilities`. Kept in step with the table by
 *  hand, because both sides are small and a mismatch should be a type error
 *  rather than a row that silently routes nowhere. */
export type Capability =
  | "video_generation"
  | "image_generation"
  | "audio_generation"
  | "voice_generation"
  | "text_generation"
  | "transcription"
  | "file_read"
  | "file_write"
  | "research"
  | "web_access";

/**
 * Why something failed, in words every provider maps onto.
 *
 * Extends the set already used by the Higgsfield path so the existing failure
 * copy and `autopilot_health` keep working unchanged -- this is a widening, not
 * a replacement.
 */
export type FailureCode =
  | "no_credits"
  | "bad_key"
  | "no_models"
  | "provider_down"
  | "rate_limited"
  | "refused"
  | "bad_request"
  | "bad_output"
  | "needs_reconnect";

/** What a failure means for the work that hit it. The caller decides what to do;
 *  the adapter only says what kind of thing happened. */
export interface Verdict {
  code: FailureCode;
  /** Worth running again unchanged, later. */
  retryable: boolean;
  /** Worth running again on a different model of the same provider. */
  tryAnotherModel: boolean;
  /** Worth running again on a different provider entirely. */
  tryAnotherProvider: boolean;
  /** The provider's own words. Stored for diagnostics, never shown as-is. */
  detail: string;
}

/** One model a connection turned out to offer. Shape matches what
 *  `record_discovery` expects, so discovery output goes straight to the
 *  database without a translation step in between. */
export interface ModelDescriptor {
  capability: Capability;
  /** Whatever the provider calls it. Opaque to everything but its own adapter. */
  external_id: string;
  label: string;
  /** Durations, resolutions, aspect ratios, cost -- whatever it reports.
   *  Deliberately unshaped: normalising this into columns would mean a
   *  migration every time a provider adds a knob. */
  metadata: Record<string, unknown>;
  /** Lower is preferred when picking "best available". */
  rank: number;
}

export interface Discovery {
  /** Who this connection belongs to, for the label. Never a credential. */
  accountLabel: string;
  externalAccountId: string | null;
  models: ModelDescriptor[];
}

/** What one connection needs to talk to its provider. Assembled by the caller
 *  from the sealed secret; an adapter never reads the database. */
export interface Authorization {
  connectionId: string;
  /** Bearer token, or the `KEY_ID:SECRET` pair for an api_key provider. */
  secret: string;
  /** Where the provider lives, from the `providers` row, so an adapter does not
   *  pin an endpoint its provider is allowed to move. */
  endpoint: string;
}

export interface SubmitRequest {
  capability: Capability;
  /** The `external_id` of the chosen model. */
  model: string;
  /** What to make. `prompt` is the only field every capability shares. */
  prompt: string;
  /** Everything else the chosen model accepts, already validated against its
   *  `metadata` by the caller. */
  options?: Record<string, unknown>;
  /** Where the provider may call back, when it supports that. Always an
   *  optimisation: no adapter may treat a callback as the completion path,
   *  because an unsigned callback that never arrives is a job lost forever. */
  webhookUrl?: string;
}

export interface Submitted {
  /** The provider's handle for this work. */
  ref: string;
  /** Where to poll, when the provider gives a URL rather than an id. */
  statusUrl?: string;
  state: "queued" | "running" | "done" | "failed";
}

export interface Polled {
  state: "queued" | "running" | "done" | "failed";
  /** Present only when done. Bytes are fetched and stored by the caller --
   *  provider URLs expire, and consent binds to a checksum. */
  outputUrl?: string;
  outputMime?: string;
  verdict?: Verdict;
}

/**
 * The contract. One file per provider, and nothing outside that file knows the
 * provider's name.
 */
export interface Adapter {
  /** Matches `providers.slug`. */
  readonly slug: string;

  /** Ask the connection what it can do. Cheap, and safe to repeat -- it is run
   *  on connect and again whenever a capability lookup finds nothing, because a
   *  provider granting access to a new model should not need a reconnect. */
  discover(auth: Authorization): Promise<Discovery>;

  submit(auth: Authorization, request: SubmitRequest): Promise<Submitted>;

  poll(auth: Authorization, submitted: Submitted): Promise<Polled>;

  /** Turn one HTTP failure into shared words. The only place a provider's own
   *  error vocabulary is allowed to be understood. */
  classify(status: number, body: unknown): Verdict;
}

/** The fallback when an adapter has nothing better to say. Deliberately
 *  pessimistic about retrying and optimistic about trying elsewhere: repeating
 *  an unexplained failure spends money for the same answer, whereas another
 *  provider is a fresh question. */
export function unknownVerdict(status: number, detail: string): Verdict {
  return {
    code: status >= 500 ? "provider_down" : "bad_request",
    retryable: status >= 500,
    tryAnotherModel: status === 404 || status === 422 || status === 400,
    tryAnotherProvider: status >= 500 || status === 404,
    detail,
  };
}
