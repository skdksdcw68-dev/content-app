import { query } from "../db.js";
import type { RoleLoop } from "../loop.js";

/**
 * Runs the chat agent, detached from any HTTP connection.
 *
 * The detachment is the point: a 30-day plan is a minute or two of model time
 * plus a dozen tool calls, and tying that to a socket on a phone means it dies
 * when the person locks the screen. `agent-send` writes a row and returns; this
 * picks it up and appends to `agent_events`, which is what the app streams.
 *
 * Handler lands in Phase 4.
 */
export const orchestrator: RoleLoop = {
  role: "orchestrator",

  async probe() {
    const rows = await query<{ n: string }>(
      `select count(*)::text n from agent_runs where status = 'queued'`
    );
    return Number(rows[0]?.n ?? 0);
  },
};
