/**
 * The generator saying it has finished.
 *
 * Higgsfield signs nothing. So this function believes exactly one thing about
 * the request it receives: that whoever sent it knew a 48-character token that
 * exists in no client, no log the app can read, and no URL a person ever sees.
 * Everything else -- whether the job finished, whether it succeeded, where the
 * file is -- is re-read from the provider with our own key before anything is
 * written down.
 *
 * That is why the body is parsed and then thrown away. It is a wake-up, not a
 * report. A forged callback with a guessed token achieves nothing except making
 * us ask Higgsfield a question we would have asked thirty seconds later anyway.
 *
 * verify_jwt is off: a provider's server carries no Supabase session. The token
 * in the path is what stands in for one.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight } from "../_shared/http.ts";
import { finishJob } from "../_shared/generate.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();

  // Always 200 to the provider unless the token is wrong. Higgsfield retries on
  // a non-2xx, and retrying is not what fixes a job we failed to ingest -- the
  // poller is. A retry storm on top of a broken ingest is two problems.
  try {
    const token = new URL(request.url).pathname.split("/").filter(Boolean).pop() ?? "";

    if (token.length < 32) {
      return json({ error: "not found" }, 404);
    }

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    const { data: job } = await admin
      .from("generation_jobs")
      .select("id, status")
      .eq("webhook_token", token)
      .maybeSingle();

    if (!job) {
      console.warn("hf-webhook: unknown token");
      return json({ error: "not found" }, 404);
    }

    await admin
      .from("generation_jobs")
      .update({ webhook_received_at: new Date().toISOString() })
      .eq("id", job.id);

    // The body is read only so the connection closes cleanly, and is not used.
    await request.text().catch(() => "");

    const outcome = await finishJob(admin, job.id);
    return json({ ok: true, state: outcome.state });
  } catch (error) {
    // Logged, acknowledged, and left to the poller. Whatever went wrong here,
    // the job still has a status_url and poll_after will bring it back.
    console.error("hf-webhook", error);
    return json({ ok: true, state: "deferred" });
  }
});
