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
  prompt?: string;
  settings?: Record<string, unknown>;
}

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
    const capability = (body.capability === "image_generation" ? "image_generation" : "video_generation") as Capability;
    if (!body.model) throw new PublicError("Which model?");

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const candidate = (await candidatesFor(admin, auth.user.id, capability)).find((c) => c.externalId === body.model);
    if (!candidate) throw new PublicError("That model isn't on your account.", 404);

    // Only the settings a card can change, and only simple values.
    const settings = Object.fromEntries(
      Object.entries(body.settings ?? {}).filter(([k, v]) =>
        ["resolution", "duration", "aspect_ratio"].includes(k) && (typeof v === "string" || typeof v === "number")
      ),
    );

    const cost = await quoteFor(admin, {
      connectionId: candidate.connectionId,
      capability,
      model: candidate.externalId,
      prompt: String(body.prompt ?? "").slice(0, 600) || "a picture",
      options: { aspect_ratio: "9:16", ...settings },
      metadata: candidate.metadata,
    });

    return json({ cost: cost ?? { unit: "unknown", amount: null, quoted: false } });
  } catch (error) {
    return fail(error);
  }
});
