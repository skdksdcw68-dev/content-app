import { env, type Role } from "./env.js";
import { closePool, query } from "./db.js";
import { log } from "./log.js";
import { runLoop, type RoleLoop } from "./loop.js";
import { orchestrator } from "./roles/orchestrator.js";
import { jobs } from "./roles/jobs.js";
import { media } from "./roles/media.js";
import { publisher } from "./roles/publisher.js";

const LOOPS: Record<Role, RoleLoop> = { orchestrator, jobs, media, publisher };

const controller = new AbortController();

/**
 * Fly sends SIGTERM and then waits before SIGKILL. Aborting lets each loop
 * finish the tick it is in and stop at a boundary, which for the publisher is
 * the difference between a clean stop and a post that was uploaded but never
 * recorded as published.
 */
function installShutdown(): void {
  let shuttingDown = false;

  for (const signal of ["SIGTERM", "SIGINT"] as const) {
    process.on(signal, () => {
      if (shuttingDown) {
        log.warn("second signal, exiting now", { signal });
        process.exit(1);
      }
      shuttingDown = true;
      log.info("shutting down", { signal });
      controller.abort();
    });
  }

  // A rejection nobody handled means the process is in a state we did not
  // design for. Stop, rather than carry on publishing from it.
  process.on("unhandledRejection", (reason) => {
    log.error("unhandled rejection", reason);
    controller.abort();
    process.exitCode = 1;
  });
}

async function main(): Promise<void> {
  installShutdown();

  // Fail fast and loudly if the database is unreachable, rather than letting
  // four loops each discover it separately and retry forever.
  const rows = await query<{ now: string }>("select now()::text as now");
  const now = rows[0]?.now ?? "unknown";
  log.info("worker starting", {
    worker: env.workerId,
    version: env.version,
    roles: env.roles,
    observeOnly: env.observeOnly,
    dbTime: now,
  });

  await Promise.all(env.roles.map((role) => runLoop(LOOPS[role], controller.signal)));

  await closePool();
  log.info("worker stopped", { worker: env.workerId });
}

main().catch((error) => {
  log.error("worker failed to start", error);
  process.exit(1);
});
