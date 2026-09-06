import { query } from "../db.js";
import type { RoleLoop } from "../loop.js";

/**
 * ffmpeg and sharp: the reason this container exists at all.
 *
 * Edge Functions cap at 2s of CPU and 256MB, which a single 1080x1920 transcode
 * blows through. This role turns whatever a provider emitted into something a
 * platform will actually accept -- PNG to JPEG above all, since generators emit
 * PNG and TikTok rejects it outright -- and writes the result to
 * `asset_variants`. The publisher reads only from there, never from the raw
 * asset, which is what makes shipping a PNG structurally impossible.
 *
 * Handler lands in Phase 3.
 */
export const media: RoleLoop = {
  role: "media",

  async probe() {
    const rows = await query<{ n: string }>(
      `select count(*)::text n
         from generation_jobs
        where kind = 'asset_normalize' and status = 'queued' and run_at <= now()`
    );
    return Number(rows[0]?.n ?? 0);
  },
};
