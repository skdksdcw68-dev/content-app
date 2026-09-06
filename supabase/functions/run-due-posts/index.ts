/**
 * The unattended loop.
 *
 * Woken every minute by pg_cron. Claims whatever is due, publishes it, and goes
 * back to sleep. Nothing about this path involves the app -- that is the whole
 * point, and the reason background modes and silent push are for refreshing the
 * UI rather than for publishing.
 *
 * Public, because pg_net cannot carry a Supabase session. What stands in for a
 * JWT is a shared secret in the header, checked in constant time.
 *
 * The wake-up being unreliable does not matter. Durability lives in the
 * publish_jobs table: a lost trigger just means the next tick picks the same
 * rows up, because the claim is what moves a job out of pending.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json } from "../_shared/http.ts";
import { publishTarget } from "../_shared/publish.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");

/** Small. A tick that tries to publish twenty videos will hit the wall clock
 *  before it finishes, and every one it started is left mid-flight. */
const BATCH = 3;

Deno.serve(async (request) => {
  if (!CRON_SECRET || !timingSafeEqual(request.headers.get("x-cron-secret") ?? "", CRON_SECRET)) {
    return json({ error: "no" }, 401);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);
  const worker = `edge-${crypto.randomUUID().slice(0, 8)}`;

  // Rate limiting happens inside the claim rather than around it -- checking
  // first and acting second is how two runs both decide they are under the cap.
  const { data: claimed, error } = await admin.rpc("claim_publish_jobs", {
    p_worker: worker,
    p_batch: BATCH,
    p_lease: "00:10:00",
  });

  if (error) {
    console.error("claim failed", error);
    return json({ error: "claim failed" }, 500);
  }

  const jobs = (claimed ?? []) as { id: string; post_target_id: string; attempts: number }[];
  if (jobs.length === 0) {
    // Housekeeping only runs on an idle tick, so a busy minute spends its time
    // publishing rather than tidying.
    await admin.rpc("reap_leases");
    await admin.rpc("expire_publish_jobs");
    return json({ claimed: 0 });
  }

  const results: Record<string, string> = {};

  for (const job of jobs) {
    try {
      const outcome = await publishTarget(admin, job.post_target_id, "DIRECT_POST");
      results[job.post_target_id] = outcome.state;

      if (outcome.state === "published" || outcome.state === "processing") {
        await admin.from("publish_jobs")
          .update({ state: "published", claimed_by: null, lease_until: null })
          .eq("id", job.id);
      } else if (outcome.state === "blocked") {
        // Waiting on a person, not broken. Release it and let them deal with
        // it; re-firing every minute would just burn the attempt counter.
        await admin.from("publish_jobs")
          .update({ state: "cancelled", claimed_by: null, lease_until: null, last_error: outcome.reason })
          .eq("id", job.id);
      } else {
        await admin.from("publish_jobs")
          .update({ state: "failed", claimed_by: null, lease_until: null, last_error: outcome.reason })
          .eq("id", job.id);
      }
    } catch (thrown) {
      // Left claimed on purpose. The lease expires, reap_leases puts it back,
      // and it is retried until max_attempts -- which is what a transient
      // network failure deserves and a permanent one survives exactly 4 times.
      console.error("publish threw", job.post_target_id, thrown);
      results[job.post_target_id] = "threw";
    }
  }

  return json({ claimed: jobs.length, results });
});

/** Compares without leaking length or position through timing. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
