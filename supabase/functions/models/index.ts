/**
 * Every model this person can reach, for one kind of work.
 *
 * The Generate card shows eight rows; this is what "all 34 models" opens
 * behind it. Nothing here is a provider's opinion dressed up as ours: the
 * names, families, descriptions and settings all come from what discovery
 * recorded, so a provider connected tomorrow lists itself.
 *
 * Unpriced by design -- see `catalogueFor`. The card prices what gets tapped.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { fail, json, preflight, PublicError } from "../_shared/http.ts";
import { catalogueFor } from "../_shared/connectors/choose.ts";
import type { Capability } from "../_shared/connectors/contract.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const KINDS: Capability[] = [
  "video_generation",
  "image_generation",
  "audio_generation",
  "voice_generation",
];

interface Body {
  capability?: string;
  withPicture?: boolean;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);
    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const body = (await request.json().catch(() => ({}))) as Body;
    const capability = KINDS.find((kind) => kind === body.capability);
    if (!capability) throw new PublicError("Which kind of model?");

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const options = await catalogueFor(admin, auth.user.id, capability, body.withPicture === true);

    return json({ capability, options });
  } catch (error) {
    return fail(error);
  }
});
