/**
 * The price of one image or video, for exactly these settings, before any of it
 * is spent.
 *
 * The Generate card asks this each time somebody changes the model, the
 * resolution or the length, so the number on the button is always the number
 * that would be charged. It is the provider's own answer -- Higgsfield's
 * `get_cost` dry run, which submits nothing -- never a figure of ours.
 *
 * Only models on the caller's own connections can be priced here: the model id
 * is looked up among their candidates, so a request cannot reach someone
 * else's account.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { fail, json, preflight, PublicError } from "../_shared/http.ts";
import { candidatesFor, quoteFor } from "../_shared/connectors/route.ts";
import type { Capability } from "../_shared/connectors/contract.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface Body {
  capability?: string;
  model?: string;
  /** Several at once -- what a family costs, asked when somebody opens it,
   *  rather than pricing a whole catalogue nobody has scrolled to. */
  models?: string[];
  prompt?: string;
  settings?: Record<string, unknown>;
}

const KINDS = ["video_generation", "image_generation", "audio_generation", "voice_generation"];
/** One tap, one screenful. Enough for the largest family and no more. */
const AT_ONCE = 12;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);
    const asUser = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authorization } } });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const body = (await request.json().catch(() => ({}))) as Body;
    const capability = (KINDS.includes(body.capability ?? "") ? body.capability : "video_generation") as Capability;
    const wanted = [...new Set([...(body.models ?? []), ...(body.model ? [body.model] : [])])].slice(0, AT_ONCE);
    if (wanted.length === 0) throw new PublicError("Which model?");

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const mine = await candidatesFor(admin, auth.user.id, capability);
    const candidates = wanted
      .map((id) => mine.find((c) => c.externalId === id))
      .filter((c): c is NonNullable<typeof c> => c !== undefined);
    if (candidates.length === 0) throw new PublicError("That model isn't on your account.", 404);

    // Only the settings a card can change, and only simple values.
    const settings = Object.fromEntries(
      Object.entries(body.settings ?? {}).filter(([k, v]) =>
        ["resolution", "duration", "aspect_ratio", "quality"].includes(k) && (typeof v === "string" || typeof v === "number")
      ),
    );

    const prompt = String(body.prompt ?? "").slice(0, 600) || "a picture";
    const priced = await Promise.all(candidates.map(async (candidate) => {
      const cost = await quoteFor(admin, {
        connectionId: candidate.connectionId,
        capability,
        model: candidate.externalId,
        prompt,
        options: { aspect_ratio: "9:16", ...settings },
        metadata: candidate.metadata,
      });
      return [candidate.externalId, cost ?? { unit: "unknown", amount: null, quoted: false }] as const;
    }));

    const costs = Object.fromEntries(priced);
    // `cost` for the card asking about one model, `costs` for a family.
    return json({ cost: costs[body.model ?? candidates[0].externalId], costs });
  } catch (error) {
    return fail(error);
  }
});
