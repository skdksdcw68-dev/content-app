/**
 * Music for the editor's sound picker: Hot, For You and search.
 *
 * TikTok's own sounds cannot be used by apps, so this is a licensed library:
 * Openverse music under CC0, public domain or CC BY -- the licences that allow
 * both commercial use and setting the music under a video. CC BY needs
 * credit, so every track carries its attribution line and the app adds it to
 * the post's description.
 *
 * Cached for six hours in music_cache: Openverse allows 200 anonymous
 * requests a day.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CACHE_HOURS = 6;
const LICENSES = "by,cc0,pdm";

/** Moods for the Hot tab; Openverse has no popularity order to borrow. */
const HOT = ["happy", "chill", "cinematic", "pop", "upbeat", "electronic", "acoustic", "hip hop"];
/** For You leans on the kind of music short product videos use. */
const FOR_YOU = ["inspiring", "energetic", "positive", "corporate", "motivational", "summer"];

interface Track {
  id: string;
  title: string;
  artist: string;
  duration_s: number;
  artwork: string | null;
  audio: string;
  license: string;
  license_url: string | null;
  attribution: string;
  source: string;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const body = (await request.json().catch(() => ({}))) as { tab?: string; q?: string };
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const tab = body.tab ?? "hot";

    if (tab === "search") {
      const q = (body.q ?? "").trim().toLowerCase().slice(0, 60);
      if (!q) throw new PublicError("Type something to search.");
      return json({ tracks: await cached(admin, `q:${q}`, () => search(q, 20)) });
    }

    const moods = tab === "for_you" ? FOR_YOU : HOT;
    const tracks = await cached(admin, tab, async () => {
      const lists = await Promise.all(moods.map((mood) => search(mood, 6).catch(() => [] as Track[])));
      // Interleave the moods so the list is varied from the top.
      const out: Track[] = [];
      for (let i = 0; i < 6; i++) for (const list of lists) if (list[i]) out.push(list[i]);
      return out.filter((track, index, all) => all.findIndex((t) => t.id === track.id) === index);
    });
    return json({ tracks });
  } catch (error) {
    return fail(error);
  }
});

async function cached(
  admin: ReturnType<typeof createClient>,
  key: string,
  load: () => Promise<Track[]>,
): Promise<Track[]> {
  const { data } = await admin.from("music_cache").select("body, fetched_at").eq("key", key).maybeSingle();
  if (data && Date.now() - new Date(data.fetched_at).getTime() < CACHE_HOURS * 3_600_000) {
    return data.body as Track[];
  }
  try {
    const fresh = await load();
    if (fresh.length > 0) {
      await admin.from("music_cache").upsert({ key, body: fresh, fetched_at: new Date().toISOString() });
    }
    return fresh;
  } catch (error) {
    // Better yesterday's list than none when Openverse is busy.
    if (data) return data.body as Track[];
    throw error;
  }
}

async function search(q: string, size: number): Promise<Track[]> {
  const url = new URL("https://api.openverse.org/v1/audio/");
  url.searchParams.set("q", q);
  url.searchParams.set("category", "music");
  url.searchParams.set("license", LICENSES);
  url.searchParams.set("page_size", String(size));
  const response = await fetch(url, { headers: { "User-Agent": "Autocast (netrocast.com)" } });
  if (response.status === 429) throw new PublicError("The music library is busy. Try again in a minute.", 429);
  if (!response.ok) throw new PublicError("The music library didn't answer.", 502);
  const data = await response.json() as { results?: Record<string, unknown>[] };
  return (data.results ?? [])
    .filter((r) => typeof r.url === "string" && typeof r.duration === "number" && (r.duration as number) >= 15_000)
    .map((r) => ({
      id: String(r.id),
      title: String(r.title ?? "Untitled").slice(0, 120),
      artist: String(r.creator ?? "Unknown").slice(0, 80),
      duration_s: Math.round((r.duration as number) / 1000),
      artwork: typeof r.thumbnail === "string" ? r.thumbnail : null,
      audio: String(r.url),
      license: `${String(r.license).toUpperCase()}${r.license_version ? ` ${r.license_version}` : ""}`,
      license_url: typeof r.license_url === "string" ? r.license_url : null,
      attribution: `🎵 ${String(r.title ?? "Untitled")} – ${String(r.creator ?? "Unknown")} (${licenseLabel(String(r.license))})`,
      source: String(r.source ?? "openverse"),
    }));
}

function licenseLabel(license: string): string {
  switch (license) {
    case "cc0": return "CC0";
    case "pdm": return "Public domain";
    default: return `CC ${license.toUpperCase()}`;
  }
}
