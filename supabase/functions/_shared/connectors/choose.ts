/**
 * Which model, and whether to ask.
 *
 * Two jobs, and they are different. `choicesFor` builds what a person sees when
 * the decision is theirs. `autoSelect` makes the decision when it is not.
 *
 * The rule that decides which happens: interrupt somebody only when the answer
 * materially changes what they get. Picking between two video models that
 * differ in cost and fidelity is worth a tap; picking the only model available
 * is not a choice, it is a dialog. So `shouldAsk` exists and is consulted
 * before anything is rendered.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import type { Balance, Capability, Constraints, Cost } from "./contract.ts";
import { candidatesFor, quoteFor } from "./route.ts";
import { suits } from "./suits.ts";

/** One row in the picker, already said the way a person reads it. */
export interface Choice {
  modelId: string;
  connectionId: string;
  provider: string;
  label: string;
  externalId: string;
  capability: Capability;
  cost: Cost;
  constraints: Constraints;
  /** Why Auto would or would not pick this. Shown under the recommended row so
   *  the recommendation is arguable rather than magic. */
  reason?: string;
  recommended: boolean;
  /** False when its price is more than the account has. Absent when either
   *  is unknown. */
  affordable?: boolean;
}

export interface Choices {
  capability: Capability;
  options: Choice[];
  /** True when the options differ in a way worth a person's attention. */
  worthAsking: boolean;
  /** What Auto would take. Always present when there is anything at all, so
   *  "Auto select" is never a button that might do nothing. */
  auto: Choice | null;
}

const UNKNOWN_COST: Cost = { unit: "unknown", amount: null, quoted: false };

/** What the person is trying to make, as far as the agent worked it out. Used
 *  to score, so Auto is answering this request rather than a general question
 *  about which model is nicest. */
export interface Intent {
  /** Seconds of video, when they said. */
  seconds?: number;
  /** "9:16" for anything heading to TikTok, which is currently everything. */
  aspectRatio?: string;
  /** Their standing preference, from brand settings. Cheap is the default and
   *  the honest one: this runs thirty times a month on somebody's own credits. */
  prefer?: "cheap" | "quality" | "fast";
  /** A model they named, or previously chose. Respected unless it cannot do
   *  what was asked. */
  preferModel?: string;
  /** When present, the providers that can say what a request costs are asked,
   *  with this prompt, before the picker is drawn -- so the price shown is the
   *  provider's own number for this job rather than "Cost not stated". */
  quote?: { prompt: string; options?: Record<string, unknown> };
  /** A picture comes with the request -- attached, or the image being
   *  animated. Decides which models can do it at all; see `suits`. */
  withPicture?: boolean;
  /** Offer only these (external ids, in this order) -- the models a name the
   *  person typed could mean. Always asked when there is more than one: the
   *  person named a model, so the choice is theirs, not Auto's. */
  only?: string[];
  /** What the account has left. A model that costs more is marked on its
   *  row and never taken by Auto -- the first animation failed "out of
   *  credits" with 26 left, because the first model on the list cost 75. */
  balance?: Balance | null;
}

/** Words that carry no identity in a model name. "v" is the version prefix:
 *  Higgsfield labels one model "Kling v3.0", and "Kling 3.0" typed by a person
 *  should be that model, not a question about which Kling. */
const NOISE = new Set(["model", "the", "use", "using", "with", "a", "an", "please", "higgsfield", "v", "version"]);

/**
 * The models a typed name could mean, best first.
 *
 * "nano banana pro2" should find Nano Banana Pro and Nano Banana 2 -- both
 * fit, and which one was meant is the person's call, not a guess. Scored on how
 * much of what they typed appears in the model's name or id, then on how little
 * else the name carries, so "soul 2" prefers "Soul 2.0" over "Soul Cinema".
 * Nothing is returned unless at least half of what they typed matched.
 */
export function matchModels<T extends { label: string; externalId: string }>(pool: T[], typed: string): T[] {
  const tokens = (text: string) =>
    text.toLowerCase()
      .replace(/([a-z])(\d)/g, "$1 $2")
      .replace(/(\d)([a-z])/g, "$1 $2")
      .split(/[^a-z0-9]+/)
      .filter((t) => t && !NOISE.has(t));

  const wanted = [...new Set(tokens(typed))];
  if (wanted.length === 0) return [];

  // Scored on the NAME people see and type. The id only breaks ties: it
  // carries tokens nobody reads -- Higgsfield's `nano_banana_2_shots` is
  // labelled "Nano Banana Pro", so counting its id let "nano banana pro2"
  // match it perfectly and alone, which would have started a paid job on a
  // model nobody meant.
  const scored = pool.map((model) => {
    const shown = new Set(tokens(model.label));
    const id = new Set(tokens(model.externalId));
    const hit = wanted.filter((t) => shown.has(t)).length;
    const idHit = wanted.filter((t) => id.has(t)).length;
    return { model, recall: hit / wanted.length, idHit, extra: shown.size - hit };
  });

  const best = Math.max(...scored.map((s) => s.recall));
  if (best < 0.5) return [];

  const seen = new Set<string>();
  return scored
    .filter((s) => s.recall === best)
    .sort((a, b) => a.extra - b.extra || b.idHit - a.idHit)
    .map((s) => s.model)
    .filter((m) => !seen.has(m.externalId) && seen.add(m.externalId))
    // Generous here; the caller narrows to one kind and then to four rows.
    .slice(0, 12);
}

/**
 * The one model a typed name settles on with nothing left to ask, or null.
 *
 * Settled means: exactly one model is named precisely what they typed ("nano
 * banana 2" is Nano Banana 2, not Nano Banana 2 Lite), or only one model's
 * name contains every word they typed. Anything looser is a question -- and a
 * question costs a tap, where a wrong guess costs credits.
 */
export function settlesOn<T extends { label: string }>(matches: T[], typed: string): T | null {
  const tokens = (text: string) =>
    text.toLowerCase().replace(/([a-z])(\d)/g, "$1 $2").replace(/(\d)([a-z])/g, "$1 $2")
      .split(/[^a-z0-9]+/).filter((t) => t && !NOISE.has(t));
  const wanted = new Set(tokens(typed));
  const covers = (m: T) => [...wanted].every((t) => new Set(tokens(m.label)).has(t));
  const exact = matches.filter((m) => {
    const shown = new Set(tokens(m.label));
    return covers(m) && shown.size === wanted.size;
  });
  if (exact.length === 1) return exact[0];
  const covering = matches.filter(covers);
  return covering.length === 1 && matches.length === 1 ? covering[0] : null;
}

/** How many rows a picker shows. A catalogue can list forty models; a person
 *  choosing between forty is not choosing. The rest stay reachable by Auto. */
const SHOWN = 8;
/** How many of those are priced -- all of them. Pricing only the first five
 *  hid the cheap models further down, and Auto picked an 18-credit video when
 *  cheaper ones were on screen unpriced. Each is a parallel round trip. */
const QUOTED = 8;

export async function choicesFor(
  admin: SupabaseClient,
  userId: string,
  capability: Capability,
  intent: Intent = {},
): Promise<Choices> {
  const everything = await candidatesFor(admin, userId, capability);
  // Only what can do this request. If the filter would leave nothing, the
  // metadata is more likely incomplete than every model unable -- so the full
  // list stands rather than a false "nothing can make this".
  const able = everything.filter((c) => suits(c.metadata, intent.withPicture === true, capability));
  let candidates = able.length > 0 ? able : everything;
  if (intent.only && intent.only.length > 0) {
    const order = intent.only;
    const named = (pool: typeof everything) =>
      pool
        .filter((c) => order.includes(c.externalId))
        .sort((a, b) => order.indexOf(a.externalId) - order.indexOf(b.externalId));
    // The same suitability rule as any other offer -- "kling" for a picture
    // from words should not offer the Kling video editor -- unless that leaves
    // nothing, in which case what they named is what they get to see.
    const suitable = named(candidates);
    candidates = suitable.length > 0 ? suitable : named(everything);
  }

  const options: Choice[] = candidates.slice(0, SHOWN).map((candidate) => {
    const metadata = candidate.metadata as {
      cost?: Cost;
      constraints?: Constraints;
    };
    return {
      modelId: candidate.modelId,
      connectionId: candidate.connectionId,
      provider: candidate.providerSlug,
      label: candidate.label,
      externalId: candidate.externalId,
      capability,
      cost: metadata.cost ?? UNKNOWN_COST,
      // Typed constraints where an adapter wrote them, otherwise read from
      // whatever the provider's catalogue returned at discovery.
      constraints: metadata.constraints ?? constraintsFrom(candidate.metadata),
      recommended: false,
    };
  });

  // Providers reuse names -- Higgsfield has two "Higgsfield Soul 2.0" and two
  // "Nano Banana Pro". Two identical rows is not a choice, so a repeated name
  // carries the model's id, and every row carries the provider's own one-line
  // description of what it is for, where there is one.
  const counts = new Map<string, number>();
  for (const option of options) counts.set(option.label, (counts.get(option.label) ?? 0) + 1);
  for (const option of options) {
    if ((counts.get(option.label) ?? 0) > 1) option.label = `${option.label} · ${option.externalId}`;
    const description = candidates.find((c) => c.externalId === option.externalId)?.metadata?.description;
    if (typeof description === "string" && description.trim() && !option.constraints.notes?.length) {
      option.constraints = { ...option.constraints, notes: [description.trim().slice(0, 90)] };
    }
  }

  if (intent.quote && options.length > 0) {
    await Promise.all(options.slice(0, QUOTED).map(async (option) => {
      const quoted = await within(8_000, quoteFor(admin, {
        connectionId: option.connectionId,
        capability,
        model: option.externalId,
        prompt: intent.quote!.prompt,
        options: intent.quote!.options,
        metadata: candidates.find((c) => c.externalId === option.externalId)?.metadata,
      }));
      if (quoted) option.cost = quoted;
    }));
  }

  // Against what they have. Said on the row, in their unit, so the picker
  // answers "can I afford this" before they tap rather than after it fails.
  const balance = intent.balance;
  if (balance) {
    for (const option of options) {
      if (option.cost.amount === null || option.cost.unit !== balance.unit) continue;
      if (option.cost.amount > balance.amount) {
        option.affordable = false;
        const note = `Needs ${trim(option.cost.amount)} ${balance.unit} — you have ${trim(balance.amount)}`;
        option.constraints = { ...option.constraints, notes: [note, ...(option.constraints.notes ?? [])] };
      } else {
        option.affordable = true;
      }
    }
  }

  const auto = pick(options.filter((o) => o.affordable !== false).length > 0
    ? options.filter((o) => o.affordable !== false)
    : options, intent);
  if (auto) {
    const chosen = options.find((option) => option.modelId === auto.modelId);
    if (chosen) {
      chosen.recommended = true;
      chosen.reason = auto.reason;
    }
  }

  return {
    capability,
    options,
    // A name that fits several models is always asked: they chose to name
    // one, so Auto deciding between their candidates would be overruling them.
    worthAsking: intent.only && options.length > 1 ? true : shouldAsk(options),
    auto: auto ?? null,
  };
}

/**
 * Is this a decision or a dialog?
 *
 * One option is not a choice. Several options that differ in nothing a person
 * can act on -- same provider, no quoted price, same constraints -- is a list
 * of names, and asking somebody to rank names they have no basis to rank is
 * how a product feels like paperwork.
 *
 * So: ask when there is more than one, AND they differ in something visible.
 */
function shouldAsk(options: Choice[]): boolean {
  if (options.length < 2) return false;

  const providers = new Set(options.map((option) => option.provider));
  if (providers.size > 1) return true;

  const priced = options.filter((option) => option.cost.amount !== null);
  if (priced.length > 1 && new Set(priced.map((o) => o.cost.amount)).size > 1) return true;

  // Different maximum resolution or duration is a real difference somebody can
  // choose on, even with no price attached.
  const shapes = new Set(
    options.map((option) =>
      JSON.stringify([
        option.constraints.resolutions?.at(-1) ?? "",
        option.constraints.durations?.at(-1) ?? "",
      ])
    ),
  );
  return shapes.size > 1;
}

/**
 * What Auto takes, and why.
 *
 * Deliberately not `options[0]`. The list is ordered by discovery rank, which
 * is a provider's opinion about its own catalogue -- useful as a tiebreak and
 * no more. This scores against what was actually asked for.
 *
 * Anything that cannot do the job is removed before scoring rather than scored
 * badly: a model that cannot produce 9:16 is not a worse choice for TikTok, it
 * is not a choice at all.
 */
function pick(options: Choice[], intent: Intent): (Choice & { reason: string }) | null {
  if (options.length === 0) return null;

  const capable = options.filter((option) => {
    const { aspectRatios, durations } = option.constraints;
    if (intent.aspectRatio && aspectRatios && !aspectRatios.includes(intent.aspectRatio)) {
      return false;
    }
    // A duration outside the accepted set is not fatal -- the adapter snaps to
    // the nearest -- so it only counts against, below.
    if (intent.seconds && durations && durations.length > 0) {
      const furthest = Math.min(...durations.map((d) => Math.abs(d - intent.seconds!)));
      if (furthest > 6) return false;
    }
    return true;
  });

  const field = capable.length > 0 ? capable : options;

  // Somebody's explicit choice wins over any score, provided it survived the
  // filter above. Overriding a named model because a heuristic disagrees is
  // how a product stops feeling like it is listening.
  const named = field.find((option) => option.externalId === intent.preferModel);
  if (named) return { ...named, reason: "You picked this one before." };

  const prefer = intent.prefer ?? "cheap";

  const scored = field.map((option) => {
    let score = 0;
    const notes: string[] = [];

    // Rank is the provider's own cheapest-first ordering. Weak signal, but the
    // only one available when nobody quotes a price -- which is the common case.
    const position = field.indexOf(option);

    if (prefer === "cheap") {
      score += (field.length - position) * 10;
      if (option.cost.amount !== null) {
        score += Math.max(0, 40 - option.cost.amount);
        notes.push(`${option.cost.amount} ${option.cost.unit}`);
      } else {
        notes.push("cheapest of the ones available");
      }
    } else if (prefer === "quality") {
      score += position * 10;
      const best = option.constraints.resolutions?.at(-1);
      if (best) {
        score += /1080/.test(best) ? 30 : 10;
        notes.push(`up to ${best}`);
      }
    } else {
      const seconds = option.constraints.typicalSeconds;
      if (seconds) {
        score += Math.max(0, 300 - seconds) / 5;
        notes.push(`usually about ${Math.round(seconds / 60)} min`);
      }
      score += (field.length - position) * 5;
    }

    // A price the provider actually quoted is worth preferring over one we
    // inferred, because it can be shown honestly.
    if (option.cost.quoted) score += 5;

    return { option, score, notes };
  });

  scored.sort((a, b) => b.score - a.score);
  const winner = scored[0];

  const why = prefer === "cheap"
    ? "Cheapest that can do it"
    : prefer === "quality"
    ? "Best quality available"
    : "Fastest available";

  return {
    ...winner.option,
    reason: winner.notes.length > 0 ? `${why} — ${winner.notes.join(", ")}.` : `${why}.`,
  };
}

/**
 * Constraints read out of a raw catalogue entry.
 *
 * A provider's catalogue says what each model accepts in its own words --
 * `aspect_ratios`, `durations`, `resolutions` -- and discovery keeps the entry
 * whole. This reads the plausible spellings so the picker can show "5 or 10s,
 * 9:16" for a model nobody typed in by hand.
 */
function constraintsFrom(raw: Record<string, unknown>): Constraints {
  const strings = (value: unknown): string[] | undefined => {
    if (!Array.isArray(value)) return undefined;
    const out = value
      .map((v) => typeof v === "string" ? v : (v as { value?: unknown; id?: unknown })?.value ?? (v as { id?: unknown })?.id)
      .filter((v): v is string => typeof v === "string");
    return out.length > 0 ? out : undefined;
  };
  const numbers = (value: unknown): number[] | undefined => {
    if (!Array.isArray(value)) return undefined;
    const out = value
      .map((v) => typeof v === "number" ? v : Number((v as { value?: unknown })?.value ?? v))
      .filter((v) => Number.isFinite(v));
    return out.length > 0 ? out : undefined;
  };
  const params = (raw.parameters ?? {}) as Record<string, { enum?: unknown; values?: unknown; options?: unknown }>;

  return {
    aspectRatios: strings(raw.aspect_ratios ?? raw.aspectRatios ?? params.aspect_ratio?.enum ?? params.aspect_ratio?.values),
    durations: numbers(raw.durations ?? params.duration?.enum ?? params.duration?.values),
    resolutions: strings(raw.resolutions ?? params.resolution?.enum ?? params.resolution?.values),
  };
}

/** 26.02 -> "26.02", 18 -> "18", 0.1234 -> "0.12". */
function trim(n: number): string {
  return String(Number(n.toFixed(2)));
}

function within<T>(ms: number, work: Promise<T>): Promise<T | null> {
  return Promise.race([work, new Promise<null>((resolve) => setTimeout(() => resolve(null), ms))]);
}

/** How a cost reads in the picker. Never a bare number: "2" means nothing, and
 *  an absent price must not look like a free one. */
export function priceLabel(cost: Cost): string {
  if (cost.unit === "unknown" || cost.amount === null) return "Cost not stated";
  if (cost.unit === "allowance") return "Included in your plan";
  if (cost.unit === "usd") return `$${cost.amount.toFixed(2)}`;
  return `${cost.amount} ${cost.unit}`;
}
