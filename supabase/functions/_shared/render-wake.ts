/**
 * Wakes the story renderer.
 *
 * The renderer (renderer/, Fly app `autocast-renderer`) is a machine that is
 * stopped while there is nothing to render: it drains `render_jobs` and exits.
 * This starts it again. Called when a render is queued and on every check of a
 * render that is still queued, so a job queued in the second the machine was
 * shutting down is picked up on the next check instead of waiting forever.
 *
 * Starting a machine that is already running is not attempted, and a missing
 * token or a Fly error is logged and swallowed: a story waiting for its render
 * is better than a story that fails because the wake-up call did.
 */

const MACHINES_API = "https://api.machines.dev/v1";

export async function wakeRenderer(): Promise<void> {
  const token = Deno.env.get("FLY_API_TOKEN");
  const app = Deno.env.get("FLY_RENDER_APP") ?? "autocast-renderer";
  if (!token) return;
  // A Fly macaroon carries its own scheme ("FlyV1 ..."); anything else is a
  // bearer token.
  const authorization = token.startsWith("FlyV1 ") ? token : `Bearer ${token}`;
  try {
    const listed = await fetch(`${MACHINES_API}/apps/${app}/machines`, { headers: { Authorization: authorization } });
    if (!listed.ok) {
      console.warn("renderer: list machines", listed.status, (await listed.text()).slice(0, 200));
      return;
    }
    const machines = (await listed.json()) as Array<{ id: string; state: string }>;
    if (machines.some((m) => m.state === "started" || m.state === "starting")) return;
    const idle = machines.find((m) => ["stopped", "suspended", "created"].includes(m.state));
    if (!idle) return;
    const started = await fetch(`${MACHINES_API}/apps/${app}/machines/${idle.id}/start`, {
      method: "POST",
      headers: { Authorization: authorization },
    });
    if (!started.ok) console.warn("renderer: start", started.status, (await started.text()).slice(0, 200));
  } catch (thrown) {
    console.warn("renderer: wake failed", thrown instanceof Error ? thrown.message : thrown);
  }
}
