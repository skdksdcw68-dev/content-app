import { env, type Role } from "./env.js";
import { query } from "./db.js";
import { log } from "./log.js";

/**
 * What one loop role has to provide.
 *
 * `probe` is read-only and always safe to run: it answers "how much work is
 * waiting" without taking any. `handle` is the part that actually claims and
 * performs work, and it is optional -- a role with no handler runs in observe
 * mode, which is how Phase 1 ships a worker that can be deployed against the
 * real database before any of the handlers exist.
 */
export interface RoleLoop {
  readonly role: Role;
  probe(): Promise<number>;
  handle?(): Promise<number>;
}

const sleep = (ms: number, signal: AbortSignal): Promise<void> =>
  new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true }
    );
  });

/**
 * Says "this process is alive and is this role".
 *
 * The watchdog reads these; a role with no beat for five minutes is how an
 * OOM-killed publisher becomes an alert instead of a day of posts that quietly
 * never went out.
 */
async function heartbeat(role: Role): Promise<void> {
  await query(
    `insert into worker_heartbeats (worker_id, role, beat_at, version)
     values ($1, $2, now(), $3)
     on conflict (worker_id) do update
       set role = excluded.role, beat_at = excluded.beat_at, version = excluded.version`,
    [`${env.workerId}:${role}`, role, env.version]
  );
}

export async function runLoop(loop: RoleLoop, signal: AbortSignal): Promise<void> {
  const { role } = loop;
  const observing = env.observeOnly || loop.handle === undefined;

  log.info("loop started", {
    role,
    worker: env.workerId,
    mode: observing ? "observe" : "work",
  });

  let backoffMs = env.pollMs;
  let lastBeat = 0;
  // Only logged when it changes, so an idle queue does not produce a line every
  // two seconds forever.
  let lastReported = -1;

  while (!signal.aborted) {
    try {
      if (Date.now() - lastBeat >= env.heartbeatMs) {
        await heartbeat(role);
        lastBeat = Date.now();
      }

      const did = observing ? 0 : await loop.handle!();

      if (observing) {
        const waiting = await loop.probe();
        if (waiting !== lastReported) {
          log.info("work waiting", { role, waiting });
          lastReported = waiting;
        }
      }

      // Found something: come straight back, there is probably more. Found
      // nothing: ease off towards the ceiling.
      backoffMs = did > 0 ? env.pollMs : Math.min(backoffMs * 2, env.idlePollMaxMs);
    } catch (error) {
      log.error("loop tick failed", error, { role });
      // A failing tick is usually the database being unreachable, and hammering
      // it makes that worse.
      backoffMs = Math.min(Math.max(backoffMs, env.pollMs) * 2, env.idlePollMaxMs);
    }

    await sleep(backoffMs, signal);
  }

  log.info("loop stopped", { role });
}
