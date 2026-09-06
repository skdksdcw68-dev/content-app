import { query } from "../db.js";
import type { RoleLoop } from "../loop.js";

/**
 * Submits generation to whichever provider the person connected, then drives it
 * to completion.
 *
 * Three completion paths on purpose, because any one alone loses work: the
 * webhook (fast, and unsigned so never trusted on its own), the poller
 * (`poll_after`, backing off), and the lease reaper (the worker died). Nothing
 * here ever waits on a generation -- submit, store `status_url`, return.
 *
 * Handler lands in Phase 3.
 */
export const jobs: RoleLoop = {
  role: "jobs",

  async probe() {
    const rows = await query<{ n: string }>(
      `select count(*)::text n
         from generation_jobs
        where (status = 'queued' and run_at <= now())
           or (status in ('submitted','running') and poll_after is not null and poll_after <= now())`
    );
    return Number(rows[0]?.n ?? 0);
  },
};
