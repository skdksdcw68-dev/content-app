/**
 * Higgsfield over its REST API, with a key the person pasted.
 *
 * This is the 0012 bring-your-own-key path, unchanged in behaviour and moved
 * behind the contract. It deliberately wraps `../higgsfield.ts` rather than
 * reimplementing it: that file holds the model chain, the body-per-model
 * knowledge and the error table mapping, all of which were arrived at by
 * running them against production, and a second copy would be a second thing to
 * get wrong.
 *
 * It stays after the MCP connector exists because not every provider offers
 * OAuth, and a person who already pasted a key should not be made to redo it.
 */

import {
  type Credential,
  MODELS,
  parseCredential,
  poll as restPoll,
  Refused,
  submit as restSubmit,
} from "../higgsfield.ts";

import {
  type Adapter,
  type Authorization,
  type Capability,
  type Discovery,
  type ModelDescriptor,
  type Polled,
  type Submitted,
  type SubmitRequest,
  unknownVerdict,
  type Verdict,
} from "./contract.ts";

function credentialFrom(auth: Authorization): Credential {
  return parseCredential(auth.secret);
}

export const higgsfieldRest: Adapter = {
  slug: "higgsfield",

  /**
   * What this key can do.
   *
   * An API key cannot be asked. Higgsfield's REST surface has no "what am I
   * entitled to" endpoint -- the only way to find out is to submit and read the
   * refusal, which is how three days of September were spent discovering that
   * Seedance was not provisioned.
   *
   * So this reports what the adapter *supports*, and truthfulness is restored
   * at submit time by the chain walking past anything the account cannot use.
   * The MCP connector does not have this problem: `tools/list` is an actual
   * answer, which is most of why it is the better door.
   */
  discover(_auth: Authorization): Promise<Discovery> {
    const models: ModelDescriptor[] = MODELS.map((model, index) => ({
      capability: "video_generation" as Capability,
      external_id: model.path,
      label: model.label,
      metadata: {
        // Every model in this list is vertical-capable; the ones that are not
        // were excluded there, for TikTok. Recorded so a chooser can say why.
        aspect_ratios: ["9:16"],
        note: "Availability depends on the Higgsfield plan behind this key.",
      },
      // The list is already cheapest-first, so position is the ranking.
      rank: index * 10,
    }));

    return Promise.resolve({
      // A key pair identifies no person. Saying so is better than inventing a
      // label, and the connect sheet already explains whose key it is.
      accountLabel: "API key",
      externalAccountId: null,
      models,
    });
  },

  async submit(auth: Authorization, request: SubmitRequest): Promise<Submitted> {
    if (request.capability !== "video_generation") {
      throw new Error(`higgsfield-rest cannot do ${request.capability}`);
    }

    const submitted = await restSubmit(credentialFrom(auth), {
      prompt: request.prompt,
      webhookUrl: request.webhookUrl,
      // The chosen model is a preference, not an instruction: the chain still
      // walks on if this account has lost access to it since discovery.
      preferModel: request.model,
      seconds: typeof request.options?.seconds === "number"
        ? request.options.seconds as number
        : undefined,
    });

    return {
      ref: submitted.requestId,
      statusUrl: submitted.statusUrl,
      state: submitted.status === "completed"
        ? "done"
        : submitted.status === "failed" || submitted.status === "canceled"
        ? "failed"
        : "running",
    };
  },

  async poll(auth: Authorization, submitted: Submitted): Promise<Polled> {
    if (!submitted.statusUrl) return { state: "queued" };

    const result = await restPoll(credentialFrom(auth), submitted.statusUrl);

    if (result.status === "queued" || result.status === "in_progress") {
      return { state: "running" };
    }

    if (result.status === "completed") {
      return { state: "done", outputUrl: result.videoUrl ?? undefined, outputMime: "video/mp4" };
    }

    return {
      state: "failed",
      verdict: {
        // nsfw is terminal and distinct: the same prompt fails the same way and
        // charges again for the privilege, so nothing about it is retryable.
        code: result.status === "nsfw" ? "refused" : "provider_down",
        retryable: false,
        tryAnotherModel: result.status !== "nsfw",
        tryAnotherProvider: result.status !== "nsfw",
        detail: result.error ?? result.status,
      },
    };
  },

  /**
   * Straight from Higgsfield's own error table, which is the only reason this
   * is trustworthy -- guessing here is how you either give up on a working
   * account or hammer a broken one.
   */
  classify(status: number, body: unknown): Verdict {
    const detail = typeof (body as { detail?: unknown })?.detail === "string"
      ? (body as { detail: string }).detail
      : String(status);

    if (status === 401) {
      return {
        code: "bad_key",
        retryable: false,
        tryAnotherModel: false,
        tryAnotherProvider: true,
        detail,
      };
    }
    if (status === 403) {
      // "Insufficient credits". No other model on this provider fixes an empty
      // balance, but another provider would.
      return {
        code: "no_credits",
        retryable: false,
        tryAnotherModel: false,
        tryAnotherProvider: true,
        detail,
      };
    }
    if (status === 404 || status === 400 || status === 422) {
      // "Request or model not found FOR THIS ACCOUNT" -- about the model, not
      // the account, which is the distinction the whole chain rests on.
      return {
        code: "no_models",
        retryable: false,
        tryAnotherModel: true,
        tryAnotherProvider: true,
        detail,
      };
    }
    if (status === 429) {
      return {
        code: "rate_limited",
        retryable: true,
        tryAnotherModel: false,
        tryAnotherProvider: true,
        detail,
      };
    }
    if (status === 423 || status === 503) {
      return {
        code: "provider_down",
        retryable: true,
        tryAnotherModel: true,
        tryAnotherProvider: true,
        detail,
      };
    }
    if (status >= 500) {
      return {
        code: "provider_down",
        retryable: true,
        tryAnotherModel: false,
        tryAnotherProvider: true,
        detail,
      };
    }

    return unknownVerdict(status, detail);
  },
};

/** Turns the error the REST layer throws back into a verdict, so a caller that
 *  catches rather than inspects a response still gets shared words. */
export function verdictFromThrown(error: unknown): Verdict {
  if (error instanceof Refused) {
    return {
      code: error.code as Verdict["code"],
      retryable: error.retryable,
      tryAnotherModel: error.code === "no_models",
      tryAnotherProvider: error.code !== "refused",
      detail: error.message,
    };
  }
  return unknownVerdict(500, error instanceof Error ? error.message : "unknown");
}
