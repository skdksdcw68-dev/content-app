/**
 * The walls of the house (0100, `app_limits`): how much one person can send,
 * attach and run at once. Abel, 5 Nov 2026: "even OpenAI and Claude have those
 * limits". These are not guesses about what a message means -- the model still
 * decides that -- only how much of it one account can push through.
 *
 * Read once per warm function and kept for five minutes, so a message does not
 * pay a database trip for numbers that change once a month. The table wins;
 * these defaults are only what holds if it cannot be read.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

export type LimitKey =
  | "message_chars"
  | "pictures_per_message"
  | "messages_per_minute"
  | "voice_note_seconds"
  | "video_upload_seconds"
  | "video_seconds"
  | "pictures_per_request"
  | "jobs_at_once"
  | "series_running"
  | "scheduled_waiting"
  | "free_messages_total";

/** Free, Pro, Max, Ultra -- plans_catalog.tier 0 to 3. */
const DEFAULTS: Record<LimitKey, [number, number, number, number]> = {
  message_chars: [20000, 20000, 20000, 20000],
  pictures_per_message: [10, 10, 10, 10],
  messages_per_minute: [20, 20, 20, 20],
  voice_note_seconds: [300, 300, 300, 300],
  video_upload_seconds: [600, 600, 600, 600],
  video_seconds: [0, 30, 60, 120],
  pictures_per_request: [0, 4, 8, 12],
  jobs_at_once: [0, 2, 4, 8],
  series_running: [0, 1, 3, 10],
  scheduled_waiting: [0, 10, 30, 100],
  // Messages a free account gets in its whole life; the paid plans use the
  // monthly meter instead, so their number here is not read.
  free_messages_total: [10, 0, 0, 0],
};

let cached: { at: number; rows: Map<string, [number, number, number, number]> } | null = null;
const KEEP_MS = 5 * 60 * 1000;

/** Every limit, from the table when it can be read. */
export async function loadLimits(admin: SupabaseClient): Promise<(key: LimitKey, tier: number) => number> {
  if (!cached || Date.now() - cached.at > KEEP_MS) {
    const rows = new Map<string, [number, number, number, number]>();
    const { data, error } = await admin.from("app_limits").select("key, free, pro, max, ultra");
    if (error) console.warn("limits not read", error.message);
    for (const row of (data ?? []) as Array<{ key: string; free: number; pro: number; max: number; ultra: number }>) {
      rows.set(row.key, [Number(row.free), Number(row.pro), Number(row.max), Number(row.ultra)]);
    }
    // A failed read is not kept, so the next message tries again.
    if (!error) cached = { at: Date.now(), rows };
    else return (key, tier) => pick(DEFAULTS[key], tier);
  }
  const rows = cached.rows;
  return (key, tier) => pick(rows.get(key) ?? DEFAULTS[key], tier);
}

function pick(values: [number, number, number, number], tier: number): number {
  return values[Math.max(0, Math.min(3, Math.round(tier)))];
}
