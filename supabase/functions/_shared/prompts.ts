import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

/**
 * The master prompts, kept on the server.
 *
 * Every step of making a video follows a master prompt (the script planner,
 * the picture prompt, the picture checker, the writers of the drawn formats).
 * They live in the table `master_prompts` so they can be improved by changing
 * a row, with no app update and no deploy. The text written in the code is the
 * fallback and the seed: if the table has no row (or cannot be read) the video
 * is made with that text, so a missing row can never stop a video.
 */

const cache = new Map<string, { body: string | null; at: number }>();
const TTL_MS = 60_000;

/** The master prompt for `key`, or `fallback` when none is saved. Cached for a minute. */
export async function masterPrompt(admin: SupabaseClient, key: string, fallback: string): Promise<string> {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < TTL_MS) return hit.body ?? fallback;
  let body: string | null = null;
  try {
    const { data } = await admin.from("master_prompts").select("body").eq("key", key).eq("enabled", true).maybeSingle();
    const text = (data as { body?: string } | null)?.body;
    body = typeof text === "string" && text.trim() ? text : null;
  } catch {
    body = null;
  }
  cache.set(key, { body, at: Date.now() });
  return body ?? fallback;
}
