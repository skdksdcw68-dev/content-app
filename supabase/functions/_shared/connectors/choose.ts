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
  /** Short tags for the row: "Cheapest", "Popular". */
  badges?: string[];
  /** The name people use for the group it belongs to -- "Kling", "Nano
   *  Banana", "Soul". Five Klings listed flat is a wall; five Klings under
   *  "Kling" is a choice. */
  family?: string;
  /** The provider's own one-line description, kept whole for the browser. */
  about?: string;
  /** False when it cannot do the request as asked -- an upscaler with nothing
   *  to upscale. Shown, and said, rather than hidden. */
  suitable?: boolean;
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
export function settlesOn<T extends { label: string; externalId?: string }>(matches: T[], typed: string): T | null {
  const tokens = (text: string) =>
    text.toLowerCase().replace(/([a-z])(\d)/g, "$1 $2").replace(/(\d)([a-z])/g, "$1 $2")
      .split(/[^a-z0-9]+/).filter((t) => t && !NOISE.has(t));
  const wanted = new Set(tokens(typed));
  const same = (text: string) => {
    const shown = new Set(tokens(text));
    return [...wanted].every((t) => shown.has(t)) && shown.size === wanted.size;
  };
  const covers = (m: T) => [...wanted].every((t) => new Set(tokens(m.label)).has(t));
  const exact = matches.filter((m) => same(m.label));
  if (exact.length === 1) return exact[0];
  // Two models the provider gave the same name -- Higgsfield calls both
  // nano_banana_pro and nano_banana_2_shots "Nano Banana Pro". The one whose
  // id is also what they typed is the one they meant; the card still shows
  // its price before anything is spent.
  if (exact.length > 1) {
    const byId = exact.filter((m) => m.externalId && same(m.externalId));
    if (byId.length === 1) return byId[0];
  }
  const covering = matches.filter(covers);
  return covering.length === 1 && matches.length === 1 ? covering[0] : null;
}

/**
 * What "you choose" means when nobody named anything.
 *
 * Names, not ids, and matched against what the person actually has: a
 * preference the catalogue does not contain falls through to the scoring
 * below, and connecting a different provider entirely still works. Abel's
 * call, after using them: Nano Banana Pro for pictures (its own default is
 * 2K), Kling 3.0 for video. Ordered, best first.
 *
 * This is a default, never a decision -- it arrives selected on a card with
 * its price, and nothing is spent until Generate.
 */
const PREFERRED: Record<string, string[]> = {
  image_generation: ["nano banana pro", "nano banana", "seedream pro", "gpt image"],
  video_generation: ["kling 3.0", "kling", "veo", "seedance"],
};

/** The model a preference names, if they have it and it can do the job. */
function preferredIn<T extends { label: string; externalId: string }>(
  pool: T[],
  capability: string,
): T | null {
  for (const name of PREFERRED[capability] ?? []) {
    const found = settlesOn(matchModels(pool, name), name) ?? matchModels(pool, name)[0];
    if (found) return found;
  }
  return null;
}

/**
 * Models grouped the way people talk about them.
 *
 * Higgsfield lists five Klings, five Nano Bananas and three Veos; the name of
 * the group is simply what its members' names have in common, so nothing has
 * to be written down here and a family nobody has heard of yet groups itself.
 */
export function familiesOf(
  models: Array<{ externalId: string; label: string; provider?: string; providerSlug?: string }>,
): Map<string, string> {
  const groups = new Map<string, Array<{ id: string; words: string[] }>>();
  for (const model of models) {
    const words = withoutHost(model.label, model.providerSlug ?? model.provider ?? "")
      .split(/\s+/).filter(Boolean);
    const key = (words[0] ?? model.label).toLowerCase().replace(/[^a-z0-9]/g, "");
    const members = groups.get(key) ?? [];
    members.push({ id: model.externalId, words });
    groups.set(key, members);
  }

  const out = new Map<string, string>();
  for (const [key, members] of groups) {
    const first = members[0].words;
    let shared = first.length;
    for (const member of members) {
      let i = 0;
      while (i < shared && i < member.words.length && member.words[i].toLowerCase() === first[i].toLowerCase()) i++;
      shared = i;
    }
    const name = shared > 0
      ? first.slice(0, shared).join(" ")
      : key.charAt(0).toUpperCase() + key.slice(1);
    for (const member of members) out.set(member.id, name);
  }
  return out;
}

/**
 * "Higgsfield Soul 2.0" is a Soul.
 *
 * Only the platform they connected through is dropped, never the model's own
 * maker: taking the maker off turned "Kling 3.0 Turbo" into a family called
 * "3.0", which then swallowed "Wan 3.0". A leading word is also kept when what
 * follows starts with a number, since "3.0 Turbo" is not a name.
 */
function withoutHost(label: string, slug: string): string {
  const words = label.trim().split(/\s+/);
  if (words.length < 2 || !slug) return label.trim();
  const host = slug.toLowerCase().replace(/[^a-z0-9]/g, "");
  const first = words[0].toLowerCase().replace(/[^a-z0-9]/g, "");
  return first === host && /^[A-Za-z]/.test(words[1]) ? words.slice(1).join(" ") : label.trim();
}

/** How many rows a picker shows. A catalogue can list forty models; a person
 *  choosing between forty is not choosing. Every one of them is still reachable
 *  -- the card opens the full list, grouped by family -- and Auto knows them
 *  all. */
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
  } else {
    // The one we would pick goes in the shown rows even when the provider
    // lists it fortieth. Before this, Nano Banana Pro was in the catalogue,
    // suited the job and simply never appeared -- "its not showing the best".
    const first = preferredIn(candidates, capability);
    if (first) candidates = [first, ...candidates.filter((c) => c.externalId !== first.externalId)];
  }

  const families = familiesOf(candidates);

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
      family: families.get(candidate.externalId),
      about: typeof candidate.metadata?.description === "string"
        ? String(candidate.metadata.description)
        : undefined,
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

  // The provider lists its catalogue most-featured first, so the order they
  // arrived in is the nearest thing to "popular" there is. Kept before the
  // re-sort below so the badge can say which one it was.
  const popular = options[0]?.modelId;

  // Cheapest first -- "better credits mean lower" -- with anything they cannot
  // afford after everything they can, and unpriced rows last of all.
  options.sort((a, b) => {
    const over = Number(a.affordable === false) - Number(b.affordable === false);
    if (over !== 0) return over;
    if (a.cost.amount === null && b.cost.amount === null) return 0;
    if (a.cost.amount === null) return 1;
    if (b.cost.amount === null) return -1;
    return a.cost.amount - b.cost.amount;
  });

  const cheapest = options.find((o) => o.cost.amount !== null && o.affordable !== false);
  if (cheapest) cheapest.badges = ["Cheapest"];
  const featured = options.find((o) => o.modelId === popular);
  if (featured && featured !== cheapest) featured.badges = [...(featured.badges ?? []), "Popular"];

  const auto = pick(options.filter((o) => o.affordable !== false).length > 0
    ? options.filter((o) => o.affordable !== false)
    : options, intent);
  if (auto) {
    const chosen = options.find((option) => option.modelId === auto.modelId);
    if (chosen) {
      chosen.recommended = true;
      chosen.reason = auto.reason;
      chosen.badges = ["Recommended", ...(chosen.badges ?? [])];
    }
  }

  // What we would take leads the list. Cheapest-first is the right order among
  // equals, but on its own it buried the model actually worth using -- which
  // read as a picker that did not know what was good. Stable, so everything
  // else keeps its cheapest-first order.
  options.sort((a, b) => Number(b.recommended) - Number(a.recommended));

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
 * Everything they have for one capability, grouped by family and unpriced.
 *
 * This is what "all 34 models" opens. Prices are not asked for here on
 * purpose: quoting thirty-four models to draw a list spends thirty-four
 * provider requests on a scroll, so a row is priced when it is tapped and the
 * families somebody actually opens can be priced together.
 *
 * Models that cannot do the request still come back, marked -- somebody
 * looking for the background remover should find it, and be told it needs a
 * picture rather than have it hidden.
 */
export async function catalogueFor(
  admin: SupabaseClient,
  userId: string,
  capability: Capability,
  withPicture = false,
): Promise<Choice[]> {
  const everything = await candidatesFor(admin, userId, capability);
  const families = familiesOf(everything);

  const options = everything.map((candidate) => {
    const metadata = candidate.metadata as { cost?: Cost; constraints?: Constraints };
    return {
      modelId: candidate.modelId,
      connectionId: candidate.connectionId,
      provider: candidate.providerSlug,
      label: candidate.label,
      externalId: candidate.externalId,
      capability,
      cost: metadata.cost ?? UNKNOWN_COST,
      constraints: metadata.constraints ?? constraintsFrom(candidate.metadata),
      recommended: false,
      family: families.get(candidate.externalId),
      about: typeof candidate.metadata?.description === "string"
        ? String(candidate.metadata.description)
        : undefined,
      suitable: suits(candidate.metadata, withPicture, capability),
    } satisfies Choice;
  });

  // Two rows reading "Nano Banana Pro" are not a choice; the id says which.
  const counts = new Map<string, number>();
  for (const option of options) counts.set(option.label, (counts.get(option.label) ?? 0) + 1);
  for (const option of options) {
    if ((counts.get(option.label) ?? 0) > 1) option.label = `${option.label} · ${option.externalId}`;
  }

  const best = preferredIn(options.filter((o) => o.suitable), capability);
  if (best) {
    const chosen = options.find((o) => o.externalId === best.externalId);
    if (chosen) {
      chosen.recommended = true;
      chosen.badges = ["Recommended"];
    }
  }

  return options;
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

  // Nobody named one and nobody set a standing preference: take the model
  // worth defaulting to, if they have it. See PREFERRED.
  if (!intent.prefer) {
    const wanted = preferredIn(field, field[0]?.capability ?? "");
    if (wanted) {
      const price = wanted.cost.amount !== null ? ` — ${trim(wanted.cost.amount)} ${wanted.cost.unit}` : "";
      return { ...wanted, reason: `Best quality for the price${price}.` };
    }
  }

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
  // Parameters come either keyed by name or -- Higgsfield's shape -- as a list
  // of {name, options, default, min, max}. Only the keyed shape was read, so
  // no model ever showed its resolutions and the picker could not offer them.
  type Param = { name?: unknown; enum?: unknown; values?: unknown; options?: unknown; default?: unknown; min?: unknown; max?: unknown };
  const listed = Array.isArray(raw.parameters) ? raw.parameters as Param[] : [];
  const keyed = !Array.isArray(raw.parameters) ? (raw.parameters ?? {}) as Record<string, Param> : {};
  const param = (name: string): Param | undefined => listed.find((p) => p.name === name) ?? keyed[name];
  const choices = (p?: Param) => p?.options ?? p?.enum ?? p?.values;

  // A duration given as a range becomes a few sensible stops inside it.
  const durationParam = param("duration");
  let durations = numbers(raw.durations ?? choices(durationParam));
  if (!durations && typeof durationParam?.min === "number" && typeof durationParam?.max === "number") {
    const lo = durationParam.min as number, hi = durationParam.max as number;
    durations = [...new Set([lo, 5, 8, 10, hi].filter((d) => d >= lo && d <= hi))].sort((a, b) => a - b);
  }

  const resolutionParam = param("resolution");
  const resolutions = strings(raw.resolutions ?? choices(resolutionParam));
  // Some models express detail as a quality tier instead of a resolution --
  // Seedream's basic/high, GPT Image's low/medium/high.
  const qualityParam = param("quality");
  const qualities = strings(choices(qualityParam));

  // Anything else it will not run without and lists the answers to: a voice,
  // an engine, a language. Asked as its own row rather than written down here,
  // so a knob added tomorrow gets asked about on its own.
  const OWN_ROW = new Set(["resolution", "quality", "duration", "aspect_ratio", "prompt", "model", "medias", "count"]);
  const asks = listed
    .filter((p) => (p.required === "required" || p.required === true) && !OWN_ROW.has(String(p.name ?? "")))
    .map((p) => {
      const name = String(p.name ?? "");
      const options = strings(choices(p)) ?? [];
      return {
        name,
        label: name.replace(/[_-]+/g, " ").replace(/^\w/, (c) => c.toUpperCase()),
        options,
        preset: typeof p.default === "string" ? p.default : undefined,
      };
    })
    .filter((ask) => ask.name && ask.options.length > 1);

  return {
    aspectRatios: strings(raw.aspect_ratios ?? raw.aspectRatios ?? choices(param("aspect_ratio"))),
    durations,
    resolutions,
    qualities,
    choices: asks.length > 0 ? asks : undefined,
    defaults: {
      resolution: typeof resolutionParam?.default === "string" ? resolutionParam.default : resolutions?.[0],
      duration: typeof durationParam?.default === "number" ? durationParam.default : durations?.[0],
      quality: typeof qualityParam?.default === "string" ? qualityParam.default : qualities?.[0],
    },
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
