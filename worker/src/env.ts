/**
 * Configuration, read once and validated loudly.
 *
 * A worker that starts with a missing variable and discovers it an hour later,
 * mid-publish, is worse than one that refuses to start at all.
 */

export type Role = "orchestrator" | "jobs" | "media" | "publisher";

const ROLES: readonly Role[] = ["orchestrator", "jobs", "media", "publisher"];

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is not set`);
  }
  return value;
}

function integer(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) {
    throw new Error(`${name} must be an integer, got ${JSON.stringify(raw)}`);
  }
  return parsed;
}

function parseRoles(raw: string): Role[] {
  const parts = raw.split(",").map((part) => part.trim()).filter(Boolean);
  const bad = parts.filter((part) => !ROLES.includes(part as Role));
  if (bad.length > 0) {
    throw new Error(`unknown role(s) ${bad.join(", ")}; valid: ${ROLES.join(", ")}`);
  }
  if (parts.length === 0) {
    throw new Error("WORKER_ROLES is empty");
  }
  return parts as Role[];
}

export const env = {
  /**
   * Transaction-pooler URL, port 6543. Session mode pins a backend per
   * connection and four polling loops would exhaust the pooler; the cost of
   * transaction mode is that LISTEN/NOTIFY does not survive it, which is why
   * every loop polls on a timer rather than subscribing.
   */
  databaseUrl: required("DATABASE_URL"),

  /** Which loops this container runs. One machine can run all four. */
  roles: parseRoles(process.env.WORKER_ROLES ?? ROLES.join(",")),

  /**
   * Identifies this process in `worker_heartbeats` and in every lease it takes.
   * Fly sets FLY_ALLOCATION_ID; locally the hostname is enough.
   */
  workerId:
    process.env.WORKER_ID ??
    process.env.FLY_ALLOCATION_ID ??
    `local-${process.pid}`,

  version: process.env.WORKER_VERSION ?? "dev",

  /** How often each loop looks for work when it last found some. */
  pollMs: integer("WORKER_POLL_MS", 2_000),

  /**
   * Ceiling for the idle backoff. An empty queue should not mean a query every
   * two seconds forever -- at four loops that is 172,800 pointless round trips
   * a day.
   */
  idlePollMaxMs: integer("WORKER_IDLE_POLL_MAX_MS", 30_000),

  heartbeatMs: integer("WORKER_HEARTBEAT_MS", 30_000),

  /** Connections per role. Deliberately small; the pooler is shared. */
  poolSize: integer("WORKER_POOL_SIZE", 5),

  /**
   * Phase 1 ships the loops without their handlers. In observe mode a loop
   * reports how much work is waiting and takes none of it, so it can run
   * against the real database without consuming attempts on jobs it cannot
   * yet perform.
   */
  observeOnly: (process.env.WORKER_OBSERVE_ONLY ?? "true") === "true",
} as const;
