import { query } from "../db.js";
import type { RoleLoop } from "../loop.js";

/**
 * The part that makes this a product rather than a planner.
 *
 * Claims through `claim_publish_jobs`, which applies the per-account rate limit
 * inside the claim rather than checking it first -- check-then-act is how two
 * workers both conclude they are under the cap. Before anything is sent it
 * re-verifies the consent digest and re-reads the creator's current settings,
 * and it fails rather than silently downgrading a post the person approved as
 * public.
 *
 * Handler lands in Phase 2 for a single hardcoded post, and is the first thing
 * in this system that has to work end to end.
 */
export const publisher: RoleLoop = {
  role: "publisher",

  async probe() {
    const rows = await query<{ n: string }>(
      `select count(*)::text n
         from publish_jobs
        where state = 'pending' and run_at <= now() and expires_at > now()`
    );
    return Number(rows[0]?.n ?? 0);
  },
};
