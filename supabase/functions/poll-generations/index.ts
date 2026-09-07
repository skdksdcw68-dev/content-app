/**
 * The path that actually guarantees a video comes back.
 *
 * The webhook is an optimisation and is treated as one. It can be lost, it can
 * arrive twice, it can arrive from somebody who guessed a token, and none of
 * that changes anything -- because this runs every minute and asks the provider
 * directly. A pipeline whose only completion path is a callback from somebody
 * else's server is a pipeline that stops working the day their retry queue has
 * a bad afternoon, and nobody finds out until a month of posts is empty.
 *
 * Same shape as run-due-posts: cron-woken, no JWT, a shared secret in constant
 * time, and a small batch so a tick finishes inside its wall clock.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json } from "../_shared/http.ts";
import { finishJob } from "../_shared/generate.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");

/** Each finished job downloads a video, so the batch is small. Ones not taken
 *  this minute are taken next minute; the queue is durable. */
const BATCH = 4;

Deno.serve(async (request) => {
  if (!CRON_SECRET || !timingSafeEqual(request.headers.get("x-cron-secret") ?? "", CRON_SECRET)) {
    return json({ error: "no" }, 401);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);
  const worker = `poll-${crypto.randomUUID().slice(0, 8)}`;

  // The claim clears poll_after, so two ticks overlapping cannot both take the
  // same job -- and if this one dies, reap_leases puts it back.
  const { data: claimed, error } = await admin.rpc("claim_pollable_jobs", {
    p_worker: worker,
    p_batch: BATCH,
    p_lease: "00:02:00",
  });

  if (error) {
    console.error("claim failed", error);
    return json({ error: "claim failed" }, 500);
  }

  const jobs = (claimed ?? []) as { id: string }[];
  if (jobs.length === 0) return json({ polled: 0 });

  const results: Record<string, string> = {};

  for (const job of jobs) {
    try {
      const outcome = await finishJob(admin, job.id);
      results[job.id] = outcome.state;

      // Only a job still running keeps a poll_after; finishJob sets it. What
      // has to happen here either way is releasing the lease, or the reaper
      // will treat a perfectly healthy job as abandoned two minutes from now.
      await admin
        .from("generation_jobs")
        .update({ claimed_by: null, lease_until: null })
        .eq("id", job.id);
    } catch (thrown) {
      console.error("poll threw", job.id, thrown);
      results[job.id] = "threw";

      // poll_after is restored explicitly rather than left to the reaper. The
      // claim cleared it, so a job that throws here has nothing bringing it
      // back -- and reap_leases would set it to `queued`, which is the SUBMIT
      // queue. That would pay for the same video twice.
      await admin
        .from("generation_jobs")
        .update({
          claimed_by: null,
          lease_until: null,
          poll_after: new Date(Date.now() + 120_000).toISOString(),
        })
        .eq("id", job.id);
    }
  }

  return json({ polled: jobs.length, results });
});

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
