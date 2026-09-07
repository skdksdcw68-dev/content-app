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
import { finishJob, startJob } from "../_shared/generate.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");
const WEBHOOK_BASE = Deno.env.get("PUBLIC_FUNCTIONS_URL") ?? `${SUPABASE_URL}/functions/v1`;

/** Each finished job downloads a video, so the batch is small. Ones not taken
 *  this minute are taken next minute; the queue is durable. */
const BATCH = 4;

/** Smaller still, because every one of these spends the person's money. Three a
 *  minute is 180 an hour, far more headroom than a plan needs, and it keeps a
 *  runaway bounded by something other than hope. */
const START_BATCH = 3;

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

  // An idle tick is where new work gets started. A busy one spends its minute
  // finishing what is already running -- downloading a 40MB video and then
  // submitting three more is how a tick runs out of wall clock halfway through
  // an ingest.
  if (jobs.length === 0) {
    return json({ polled: 0, started: await startDueRenders(admin) });
  }

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

/**
 * Starts the media for posts whose slot is close enough to be worth paying for.
 *
 * This is the line between "press Make it thirty times" and an autopilot. It is
 * gated on `brand_settings.is_on`, which defaults to FALSE and is a switch a
 * person has to find and turn on -- because everything below this comment
 * spends their money without asking again.
 *
 * T-26h rather than at plan time, for two reasons that both matter: thirty
 * videos generated on approval is real money spent on posts that may be
 * discarded, and provider outputs expire in about a week, so day thirty would
 * rot before it ever published.
 */
async function startDueRenders(admin: ReturnType<typeof createClient>): Promise<number> {
  const { data: due, error } = await admin.rpc("due_for_render", { p_limit: START_BATCH });

  if (error) {
    console.error("due_for_render", error);
    return 0;
  }

  const rows = (due ?? []) as Array<{
    post_id: string;
    user_id: string;
    brand_id: string;
    prompt: string;
  }>;

  let started = 0;

  for (const row of rows) {
    try {
      await startJob(admin, {
        userId: row.user_id,
        postId: row.post_id,
        brandId: row.brand_id,
        prompt: row.prompt,
        webhookBase: WEBHOOK_BASE,
      });
      started += 1;
    } catch (thrown) {
      // The commonest cause is a person turning autopilot on without a
      // generator connected. Recorded on the post so they can see why nothing
      // happened, rather than left as a day that silently stays empty.
      const reason = thrown instanceof Error ? thrown.message : "could not start";
      console.error("startDueRenders", row.post_id, reason);

      await admin
        .from("posts")
        .update({ status: "failed", failure_reason: reason })
        .eq("id", row.post_id);
    }
  }

  return started;
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
