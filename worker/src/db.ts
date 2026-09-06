import pg from "pg";
import { env } from "./env.js";
import { log } from "./log.js";

/**
 * One pool per process, sized small on purpose: the pooler is shared with the
 * Edge Functions and with Realtime, and four loops each opening a generous pool
 * is how a project runs out of connections at the worst possible moment.
 */
const pool = new pg.Pool({
  connectionString: env.databaseUrl,
  max: env.poolSize,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
  application_name: `autocast-worker/${env.workerId}`,
});

// An idle client erroring out must not take the process with it. Postgres drops
// idle connections on its own schedule and pg surfaces that here.
pool.on("error", (error) => {
  log.error("idle client error", error);
});

export async function query<T extends pg.QueryResultRow>(
  text: string,
  params: readonly unknown[] = []
): Promise<T[]> {
  const result = await pool.query<T>(text, params as unknown[]);
  return result.rows;
}

/**
 * Runs `fn` inside a transaction, rolling back on any throw.
 *
 * Claiming is transactional by nature: FOR UPDATE SKIP LOCKED only holds while
 * the transaction is open, so a claim and the work it authorises have to agree
 * about where the boundary is.
 */
export async function transaction<T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("begin");
    const result = await fn(client);
    await client.query("commit");
    return result;
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      log.error("rollback failed", rollbackError);
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function closePool(): Promise<void> {
  await pool.end();
}
