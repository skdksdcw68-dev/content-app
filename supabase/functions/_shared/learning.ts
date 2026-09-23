/**
 * What Autocast learned, from what actually happened.
 *
 * Deterministic on purpose. A model asked "what patterns do you see in these 14
 * videos?" will always see some, and state them with confidence -- the exact
 * thing Abel's brief forbids: "Do NOT present weak conclusions as facts." So a
 * finding here is a fixed test with fixed thresholds:
 *
 *   - Nothing at all under MIN_VIDEOS videos with numbers.
 *   - Each side of a comparison needs MIN_GROUP videos.
 *   - Medians, not means, so one viral post cannot carry a group.
 *   - The difference must be at least MIN_LIFT.
 *   - It must STILL hold with the single biggest video removed. A pattern that
 *     disappears without one post was that post, not a pattern.
 *
 * Confidence is read from sample size and effect, never chosen by a model.
 * Recommendations are derived only from findings that passed, and each carries
 * the fact that Apply writes into brand_memory -- which the planner and Chat
 * read -- so acting on one changes what gets made next.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

const MIN_VIDEOS = 10;
const MIN_GROUP = 5;
const MIN_LIFT = 0.25;
/** After removing the biggest video, the effect may shrink but not below this. */
const ROBUST_LIFT = 0.15;

interface Row {
  video_id: string;
  platform: string;
  posted_at: string | null;
  duration_s: number | null;
  description: string | null;
  views: number;
  likes: number;
  comments: number;
  shares: number;
  hook: string | null;
  format: string | null;
  pillar: string | null;
  source: string | null;
  timezone: string;
}

type Confidence = "low" | "medium" | "high";

interface Test {
  key: string;
  /** Which side a video is on, or null when the test does not apply to it. */
  side: (row: Row) => "a" | "b" | null;
  /** How each side reads in a sentence: "videos under 20 seconds". */
  a: string;
  b: string;
  /** The recommendation when that side wins. */
  adviceA: string;
  adviceB: string;
  contentTypes: string[];
}

interface Finding {
  test: Test;
  winner: "a" | "b";
  lift: number;
  liftWithoutTop: number;
  nWin: number;
  nLose: number;
  medWin: number;
  medLose: number;
  confidence: Confidence;
  rows: Row[];
}

export interface LearnResult {
  videos: number;
  insights: number;
  recommendations: number;
}

function median(values: number[]): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((x, y) => x - y);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function localParts(iso: string, timezone: string): { hour: number; weekday: string } {
  const date = new Date(iso);
  const hour = Number(new Intl.DateTimeFormat("en-GB", { hour: "numeric", hourCycle: "h23", timeZone: timezone }).format(date));
  const weekday = new Intl.DateTimeFormat("en-GB", { weekday: "short", timeZone: timezone }).format(date);
  return { hour, weekday };
}

function compact(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1).replace(/\.0$/, "")}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1).replace(/\.0$/, "")}K`;
  return `${Math.round(n)}`;
}

function percent(lift: number): string {
  return `${Math.round(lift * 100)}%`;
}

function cap(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** The fixed tests. Categorical ones (format, theme) are built from the data. */
function tests(rows: Row[]): Test[] {
  const out: Test[] = [
    {
      key: "duration",
      side: (r) => r.duration_s == null ? null : r.duration_s < 20 ? "a" : "b",
      a: "videos under 20 seconds",
      b: "videos of 20 seconds or more",
      adviceA: "Keep videos under 20 seconds",
      adviceB: "Give videos more than 20 seconds",
      contentTypes: ["video"],
    },
    {
      key: "caption_length",
      side: (r) => !r.description ? null : r.description.length <= 100 ? "a" : "b",
      a: "posts with short captions (100 characters or fewer)",
      b: "posts with longer captions",
      adviceA: "Keep captions short",
      adviceB: "Write fuller captions",
      contentTypes: ["video", "photo", "carousel"],
    },
    {
      key: "evening",
      side: (r) => {
        if (!r.posted_at) return null;
        const { hour } = localParts(r.posted_at, r.timezone);
        return hour >= 17 && hour <= 22 ? "a" : "b";
      },
      a: "posts published in the evening (5-11 PM)",
      b: "posts published at other times",
      adviceA: "Test posting between 5 and 11 PM",
      adviceB: "Test posting earlier in the day",
      contentTypes: ["video", "photo", "carousel"],
    },
    {
      key: "weekend",
      side: (r) => {
        if (!r.posted_at) return null;
        const { weekday } = localParts(r.posted_at, r.timezone);
        return weekday === "Sat" || weekday === "Sun" ? "a" : "b";
      },
      a: "weekend posts",
      b: "weekday posts",
      adviceA: "Post more on weekends",
      adviceB: "Post more on weekdays",
      contentTypes: ["video", "photo", "carousel"],
    },
    {
      key: "hook_length",
      side: (r) => {
        if (!r.hook) return null;
        return r.hook.trim().split(/\s+/).length <= 8 ? "a" : "b";
      },
      a: "posts with short hooks (8 words or fewer)",
      b: "posts with longer hooks",
      adviceA: "Keep hooks to 8 words or fewer",
      adviceB: "Let hooks run longer than 8 words",
      contentTypes: ["video"],
    },
    {
      key: "autopilot",
      side: (r) => r.source === "generated" ? "a" : r.source ? "b" : null,
      a: "videos Autopilot made",
      b: "videos you made yourself",
      adviceA: "Let Autopilot make more of the videos",
      adviceB: "Keep your own videos in the mix",
      contentTypes: ["video"],
    },
  ];

  // One categorical test per dimension: the biggest group against the rest.
  // Testing every category and keeping the best would find a winner by chance.
  for (const [dimension, pick, label] of [
    ["format", (r: Row) => r.format, (v: string) => `${v} posts`],
    ["pillar", (r: Row) => r.pillar, (v: string) => `posts about ${v}`],
  ] as const) {
    const counts = new Map<string, number>();
    for (const row of rows) {
      const value = pick(row);
      if (value) counts.set(value, (counts.get(value) ?? 0) + 1);
    }
    if (counts.size < 2) continue;
    const [largest] = [...counts.entries()].sort((x, y) => y[1] - x[1])[0];
    out.push({
      key: `${dimension}:${largest}`,
      side: (r) => {
        const value = pick(r);
        return value == null ? null : value === largest ? "a" : "b";
      },
      a: label(largest),
      b: dimension === "format" ? "other formats" : "other themes",
      adviceA: dimension === "format" ? `Make more ${largest} posts` : `Publish more about ${largest}`,
      adviceB: dimension === "format" ? `Post fewer ${largest} posts` : `Publish less about ${largest}`,
      contentTypes: dimension === "format" ? [largest] : ["video", "photo", "carousel"],
    });
  }

  return out;
}

function evaluate(test: Test, rows: Row[], topVideo: string | null): Finding | null {
  const measure = (subset: Row[]) => {
    const a = subset.filter((r) => test.side(r) === "a");
    const b = subset.filter((r) => test.side(r) === "b");
    return { a, b, medA: median(a.map((r) => r.views)), medB: median(b.map((r) => r.views)) };
  };

  const all = measure(rows);
  if (all.a.length < MIN_GROUP || all.b.length < MIN_GROUP) return null;
  if (all.medA <= 0 || all.medB <= 0) return null;

  const winner: "a" | "b" = all.medA >= all.medB ? "a" : "b";
  const medWin = winner === "a" ? all.medA : all.medB;
  const medLose = winner === "a" ? all.medB : all.medA;
  const lift = medWin / medLose - 1;
  if (lift < MIN_LIFT) return null;

  const without = measure(rows.filter((r) => r.video_id !== topVideo));
  const winWithout = winner === "a" ? without.medA : without.medB;
  const loseWithout = winner === "a" ? without.medB : without.medA;
  if (loseWithout <= 0 || without.a.length < MIN_GROUP - 1 || without.b.length < MIN_GROUP - 1) return null;
  const liftWithoutTop = winWithout / loseWithout - 1;
  if (liftWithoutTop < ROBUST_LIFT) return null;

  const nWin = winner === "a" ? all.a.length : all.b.length;
  const nLose = winner === "a" ? all.b.length : all.a.length;
  const smaller = Math.min(nWin, nLose);
  const confidence: Confidence = smaller >= 15 && lift >= 0.4 ? "high" : smaller >= 8 ? "medium" : "low";

  return {
    test, winner, lift, liftWithoutTop, nWin, nLose, medWin, medLose, confidence,
    rows: [...all.a, ...all.b],
  };
}

interface Drift {
  statement: string;
  because: string;
  sample: number;
  evidence: Record<string, unknown>;
  from: string | null;
  to: string | null;
  platforms: string[];
}

const DRIFT_WINDOW = 6;
const DRIFT_MIN = 5;

/** The last few posts, and whether any theme came back. A theme is the
 *  post's pillar when it has one, else its format -- never a guess from the
 *  words. Nothing is said until enough posts carry one. */
function driftFinding(rows: Row[]): Drift | null {
  const recent = rows
    .filter((r) => r.posted_at)
    .sort((x, y) => (y.posted_at ?? "").localeCompare(x.posted_at ?? ""))
    .slice(0, DRIFT_WINDOW);
  const themed = recent
    .map((r) => ({ row: r, theme: (r.pillar || r.format || "").trim().toLowerCase() }))
    .filter((t) => t.theme);
  if (themed.length < DRIFT_MIN) return null;

  const counts = new Map<string, number>();
  for (const t of themed) counts.set(t.theme, (counts.get(t.theme) ?? 0) + 1);
  const distinct = counts.size;
  // Every post its own direction, or all but one: that is what "changing
  // your content constantly" looks like in the data.
  if (distinct < themed.length - 1) return null;

  const posted = themed.map((t) => t.row.posted_at as string).sort();
  const names = [...counts.keys()];
  return {
    statement: `Your last ${themed.length} posts went ${distinct} different directions.`,
    because: `Of your last ${themed.length} posts, ${distinct} had a different theme (${names.join(", ")}). Viewers who like one post cannot tell what the next will be, so fewer of them follow.`,
    sample: themed.length,
    evidence: { window: themed.length, distinct_themes: distinct, themes: names, rule: `Last ${DRIFT_WINDOW} posts with a theme; flagged when at most one theme repeats.` },
    from: posted[0] ?? null,
    to: posted[posted.length - 1] ?? null,
    platforms: [...new Set(themed.map((t) => t.row.platform))],
  };
}

/** Recomputes a brand's findings and recommendations. Safe to run often. */
export async function learn(admin: SupabaseClient, brandId: string, userId: string): Promise<LearnResult> {
  const { data, error } = await admin.rpc("learning_input", { p_brand: brandId });
  if (error) throw new Error(`learning_input: ${error.message}`);
  const rows = ((data ?? []) as Row[]).map((r) => ({
    ...r,
    views: Number(r.views ?? 0),
    likes: Number(r.likes ?? 0),
    comments: Number(r.comments ?? 0),
    shares: Number(r.shares ?? 0),
  }));

  const { data: existingRecs } = await admin
    .from("recommendations")
    .select("id, key, status")
    .eq("brand_id", brandId);
  const recStatus = new Map<string, string>(
    ((existingRecs ?? []) as Array<{ key: string; status: string }>).map((r) => [r.key, r.status]),
  );

  const keptInsights: string[] = [];
  const keptRecs: string[] = [];

  // Consistency, from fewer videos than the lift tests need. Abel,
  // 23 Sep 2026: "it should understand your content from your few videos...
  // if you are changing your content constantly, it should tell you
  // directly." Deterministic: the last six posts with a theme, and whether
  // any theme repeats. Six different directions in six posts is a fact, not
  // a judgement about performance.
  const drift = driftFinding(rows);
  if (drift) {
    const { data: saved, error: driftError } = await admin
      .from("insights")
      .upsert({
        user_id: userId,
        brand_id: brandId,
        key: "consistency",
        statement: drift.statement,
        metric: "themes per post",
        // Not a lift test; the column is not null, so zero says "none".
        lift: 0,
        sample_size: drift.sample,
        confidence: "medium",
        evidence: drift.evidence,
        period_start: drift.from,
        period_end: drift.to,
        platforms: drift.platforms,
        content_types: ["video"],
        status: "active",
        computed_at: new Date().toISOString(),
      }, { onConflict: "brand_id,key" })
      .select("id")
      .single();
    if (driftError) {
      console.error("learn: consistency", driftError.message);
    } else {
      keptInsights.push("consistency");
      const recKey = "consistency:focus";
      keptRecs.push(recKey);
      const status = recStatus.get(recKey);
      if (status !== "applied" && status !== "planned" && status !== "ignored") {
        const { error: recError } = await admin.from("recommendations").upsert({
          user_id: userId,
          brand_id: brandId,
          insight_id: (saved as { id: string }).id,
          key: recKey,
          title: "Stay on two themes for the next two weeks",
          because: drift.because,
          confidence: "medium",
          action: {
            fact: `Measured on this account: ${drift.statement}`,
            brief: "Keep the next two weeks to two themes, so viewers learn what this account is for.",
          },
          status: "open",
          updated_at: new Date().toISOString(),
        }, { onConflict: "brand_id,key" });
        if (recError) console.error("learn: consistency rec", recError.message);
      }
    }
  }

  if (rows.length >= MIN_VIDEOS) {
    const top = [...rows].sort((x, y) => y.views - x.views)[0]?.video_id ?? null;
    const findings = tests(rows)
      .map((test) => evaluate(test, rows, top))
      .filter((f): f is Finding => f !== null);

    for (const f of findings) {
      const win = f.winner === "a" ? f.test.a : f.test.b;
      const lose = f.winner === "a" ? f.test.b : f.test.a;
      const advice = f.winner === "a" ? f.test.adviceA : f.test.adviceB;
      const posted = f.rows.map((r) => r.posted_at).filter((v): v is string => Boolean(v)).sort();
      const platforms = [...new Set(f.rows.map((r) => r.platform))];
      const sample = f.nWin + f.nLose;

      const statement = `${cap(win)} are getting more views than ${lose}.`;
      const evidence = {
        metric: "median views",
        winner: { label: win, posts: f.nWin, median_views: Math.round(f.medWin) },
        loser: { label: lose, posts: f.nLose, median_views: Math.round(f.medLose) },
        lift: Number(f.lift.toFixed(3)),
        lift_without_top_video: Number(f.liftWithoutTop.toFixed(3)),
        rule: `Needs ${MIN_GROUP}+ videos on each side, a ${percent(MIN_LIFT)}+ difference in median views, and still ${percent(ROBUST_LIFT)}+ without the single biggest video.`,
      };

      const { data: saved, error: insightError } = await admin
        .from("insights")
        .upsert({
          user_id: userId,
          brand_id: brandId,
          key: f.test.key,
          statement,
          metric: "median views",
          lift: Number(f.lift.toFixed(3)),
          sample_size: sample,
          confidence: f.confidence,
          evidence,
          period_start: posted[0] ?? null,
          period_end: posted[posted.length - 1] ?? null,
          platforms,
          content_types: f.test.contentTypes,
          status: "active",
          computed_at: new Date().toISOString(),
        }, { onConflict: "brand_id,key" })
        .select("id")
        .single();
      if (insightError) {
        console.error("learn: insight", f.test.key, insightError.message);
        continue;
      }
      keptInsights.push(f.test.key);

      const recKey = `${f.test.key}:${f.winner}`;
      keptRecs.push(recKey);
      const status = recStatus.get(recKey);
      // What the person already decided stays decided.
      if (status === "applied" || status === "planned" || status === "ignored") continue;

      const because = `${cap(win)} got a median ${compact(f.medWin)} views across ${f.nWin} posts, against ${compact(f.medLose)} across ${f.nLose} for ${lose} (+${percent(f.lift)}). It still holds without your single biggest video.` +
        (f.confidence === "low" ? " Early signal: worth testing, not proven." : "");
      const fact = `Measured on this account (${sample} posts, ${f.confidence} confidence): ${statement} Median ${compact(f.medWin)} vs ${compact(f.medLose)} views.`;

      const { error: recError } = await admin.from("recommendations").upsert({
        user_id: userId,
        brand_id: brandId,
        insight_id: (saved as { id: string }).id,
        key: recKey,
        title: advice,
        because,
        confidence: f.confidence,
        action: { fact, brief: `${advice}. ${statement}` },
        status: "open",
        updated_at: new Date().toISOString(),
      }, { onConflict: "brand_id,key" });
      if (recError) console.error("learn: recommendation", recKey, recError.message);
    }

    // One post far above the rest is worth remaking -- as a test, never as a
    // pattern, which is why it is always low confidence.
    const medianViews = median(rows.map((r) => r.views));
    const best = [...rows].sort((x, y) => y.views - x.views)[0];
    if (best && medianViews > 0 && best.views >= medianViews * 3) {
      const name = (best.hook || best.description || "your top post").slice(0, 60);
      const recKey = `reuse:${best.video_id}`;
      keptRecs.push(recKey);
      const status = recStatus.get(recKey);
      if (status !== "applied" && status !== "planned" && status !== "ignored") {
        const ratio = (best.views / medianViews).toFixed(1);
        const { error: reuseError } = await admin.from("recommendations").upsert({
          user_id: userId,
          brand_id: brandId,
          insight_id: null,
          key: recKey,
          title: `Make variations of "${name}"`,
          because: `It got ${compact(best.views)} views, ${ratio}x your median across ${rows.length} videos. One post is not a pattern, so treat this as a test.`,
          confidence: "low",
          action: {
            fact: `Measured on this account: the post "${name}" got ${compact(best.views)} views, ${ratio}x the account's median across ${rows.length} videos.`,
            brief: `Make variations of our best post so far, "${name}": same structure and angle, new examples.`,
          },
          status: "open",
          updated_at: new Date().toISOString(),
        }, { onConflict: "brand_id,key" });
        if (reuseError) console.error("learn: reuse", reuseError.message);
      }
    }
  }

  // Anything that no longer passes is retired, not deleted: the history of what
  // was once believed stays readable. Decisions the person made are left alone.
  const { data: activeInsights } = await admin
    .from("insights").select("key").eq("brand_id", brandId).eq("status", "active");
  const staleInsights = ((activeInsights ?? []) as Array<{ key: string }>)
    .map((r) => r.key).filter((key) => !keptInsights.includes(key));
  if (staleInsights.length > 0) {
    await admin.from("insights").update({ status: "retired" }).eq("brand_id", brandId).in("key", staleInsights);
  }
  const staleRecs = ((existingRecs ?? []) as Array<{ key: string; status: string }>)
    .filter((r) => r.status === "open" && !keptRecs.includes(r.key)).map((r) => r.key);
  if (staleRecs.length > 0) {
    await admin.from("recommendations").update({ status: "retired" }).eq("brand_id", brandId).in("key", staleRecs);
  }

  return { videos: rows.length, insights: keptInsights.length, recommendations: keptRecs.length };
}
