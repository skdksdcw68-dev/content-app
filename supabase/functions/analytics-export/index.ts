/**
 * Analytics as a file: the report on screen, with its filters and date range.
 *
 * Built from the same `analytics_report`, `autopilot_report`, insights and
 * recommendations the Analytics screen and Chat read, run as the person, so the
 * file cannot say anything the screen does not. Every figure keeps its status:
 * a metric TikTok does not give is written as "Not available for this
 * platform", and a period Autocast was not yet reading is "Not enough history",
 * never 0.
 *
 * The file becomes an artefact in the person's own storage folder, like every
 * other export, and the app opens it from there.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json, preflight, fail, PublicError } from "../_shared/http.ts";
import { buildPdf, type Document } from "../_shared/exports.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

interface Body {
  brand_id?: string;
  from?: string;
  to?: string;
  platform?: string | null;
  format?: string | null;
  pillar?: string | null;
  plan?: string | null;
  file?: "csv" | "pdf";
}

// deno-lint-ignore no-explicit-any
type Json = any;

const METRICS: Array<[string, string]> = [
  ["views", "Views"], ["reach", "Reach"], ["likes", "Likes"], ["comments", "Comments"],
  ["shares", "Shares"], ["saves", "Saves"], ["followers_gained", "Followers gained"],
  ["engagement_rate", "Engagement rate"], ["avg_watch_time", "Average watch time"],
  ["avg_retention", "Average retention"], ["profile_visits", "Profile visits"],
  ["link_clicks", "Link / CTA clicks"], ["conversions", "Conversions"],
];

const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;

function csvCell(value: unknown): string {
  const text = value === null || value === undefined ? "" : String(value);
  return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function csvRow(values: unknown[]): string {
  return values.map(csvCell).join(",");
}

/** One metric's value for a period, and why it is blank when it is. */
function metricValue(report: Json, key: string, period: "current" | "previous"): { value: number | null; note: string } {
  const status = report.availability?.[key] ?? "unavailable";
  if (status === "unavailable") return { value: null, note: "Not available for this platform" };
  const totals = report.totals?.[period];
  if (!totals) return { value: null, note: "Not enough history" };

  if (key === "followers_gained") {
    if (report.filtered) return { value: null, note: "Not available with a content filter" };
    if (!totals.accounts) return { value: null, note: "No readings" };
    if (totals.followers_unknown > 0 || totals.followers === null) return { value: null, note: "Not enough history" };
    return { value: Number(totals.followers), note: "Actual" };
  }

  if (!totals.videos) return { value: null, note: "No videos" };
  if (totals.unknown > 0) return { value: null, note: "Not enough history" };

  if (key === "engagement_rate") {
    const views = Number(totals.views ?? 0);
    if (views <= 0) return { value: null, note: "No views in range" };
    const engaged = Number(totals.likes ?? 0) + Number(totals.comments ?? 0) + Number(totals.shares ?? 0);
    return { value: Number((engaged / views).toFixed(4)), note: "Derived from actual numbers" };
  }

  const raw = totals[key];
  return raw === null || raw === undefined ? { value: null, note: "Not enough history" } : { value: Number(raw), note: "Actual" };
}

function change(current: number | null, previous: number | null): string {
  if (current === null || previous === null) return "";
  if (previous === 0) return current === 0 ? "0%" : "";
  const pct = ((current - previous) / previous) * 100;
  return `${pct >= 0 ? "+" : ""}${pct.toFixed(1)}%`;
}

function display(key: string, value: number | null): string {
  if (value === null) return "";
  return key === "engagement_rate" ? `${(value * 100).toFixed(2)}%` : String(value);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);

    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const body = (await request.json().catch(() => ({}))) as Body;
    const file = body.file === "pdf" ? "pdf" : "csv";
    if (!body.brand_id || !body.from || !body.to || !DATE_ONLY.test(body.from) || !DATE_ONLY.test(body.to)) {
      throw new PublicError("Choose a brand and a date range first.", 400);
    }

    const { data: brand } = await asUser.from("brands").select("id, name").eq("id", body.brand_id).maybeSingle();
    if (!brand) throw new PublicError("That brand is not yours.", 404);

    const params = {
      p_brand: brand.id, p_from: body.from, p_to: body.to,
      p_platform: body.platform ?? null, p_format: body.format ?? null,
      p_pillar: body.pillar ?? null, p_plan: body.plan ?? null,
    };

    const [reportRead, autopilotRead, insightsRead, recsRead] = await Promise.all([
      asUser.rpc("analytics_report", params),
      asUser.rpc("autopilot_report", { p_brand: brand.id, p_from: body.from, p_to: body.to }),
      asUser.from("insights").select("statement, sample_size, confidence, lift, period_start, period_end, platforms")
        .eq("brand_id", brand.id).eq("status", "active").order("sample_size", { ascending: false }),
      asUser.from("recommendations").select("title, because, confidence, status")
        .eq("brand_id", brand.id).in("status", ["open", "applied", "planned"]).order("created_at", { ascending: false }),
    ]);
    if (reportRead.error) throw new Error(`analytics_report: ${reportRead.error.message}`);
    const report = reportRead.data as Json;
    if (!report) throw new PublicError("Nothing to export for that brand.", 404);
    const autopilot = autopilotRead.data as Json;
    const insights = (insightsRead.data ?? []) as Json[];
    const recs = (recsRead.data ?? []) as Json[];

    const filters = [
      body.platform ? `platform ${body.platform}` : null,
      body.format ? `format ${body.format}` : null,
      body.pillar ? `theme ${report.filters?.pillars?.find((p: Json) => p.id === body.pillar)?.name ?? body.pillar}` : null,
      body.plan ? `campaign ${report.filters?.campaigns?.find((p: Json) => p.id === body.plan)?.name ?? body.plan}` : null,
    ].filter(Boolean).join(", ");
    const scope = `${body.from} to ${body.to}, compared with ${report.range.prev_from} to ${report.range.prev_to}${filters ? `; ${filters}` : ""}`;
    const base = `${brand.name.replace(/[^A-Za-z0-9]+/g, "-").replace(/^-|-$/g, "") || "autocast"}-analytics-${body.from}-to-${body.to}`;

    let bytes: Uint8Array;
    let mime: string;
    let filename: string;

    if (file === "csv") {
      const lines: string[] = [];
      lines.push(csvRow([`${brand.name} analytics`]));
      lines.push(csvRow(["Range", scope]));
      lines.push(csvRow(["History starts", report.history_starts ?? "No readings yet"]));
      lines.push("");
      lines.push(csvRow(["Metric", "Current", "Previous", "Change", "Status"]));
      for (const [key, label] of METRICS) {
        const current = metricValue(report, key, "current");
        const previous = metricValue(report, key, "previous");
        lines.push(csvRow([label, display(key, current.value), display(key, previous.value), change(current.value, previous.value), current.note]));
      }
      lines.push("");
      lines.push(csvRow(["Trend", `grouped by ${report.range.grain}`]));
      lines.push(csvRow(["Period", "Start", "End", "Views", "Likes", "Comments", "Shares", "Followers gained", "Complete"]));
      for (const b of report.series as Json[]) {
        const complete = b.videos > 0 && b.unknown === 0;
        lines.push(csvRow([b.period, b.start, b.end,
          complete ? b.views : "", complete ? b.likes : "", complete ? b.comments : "", complete ? b.shares : "",
          b.accounts > 0 && b.followers_unknown === 0 && !report.filtered ? b.followers : "",
          complete ? "yes" : "no"]));
      }
      lines.push("");
      lines.push(csvRow(["Top content", report.top_scope === "posted_in_range" ? "posted in range, lifetime numbers" : "all time, lifetime numbers"]));
      lines.push(csvRow(["Title", "Platform", "Posted", "Views", "Likes", "Comments", "Shares", "Engagement rate", "vs median", "Format", "Theme", "Link"]));
      for (const v of report.top as Json[]) {
        lines.push(csvRow([v.hook || v.title || v.description || "", v.platform, v.posted_at ?? "", v.views, v.likes, v.comments, v.shares,
          v.engagement_rate === null ? "" : `${(v.engagement_rate * 100).toFixed(2)}%`,
          v.relative === null ? "" : `${v.relative}x`, v.format ?? "", v.pillar ?? "", v.share_url ?? ""]));
      }
      lines.push("");
      lines.push(csvRow(["What Autocast learned"]));
      lines.push(csvRow(["Finding", "Posts", "Median views difference", "Confidence", "From", "To", "Platforms"]));
      if (insights.length === 0) lines.push(csvRow(["Not enough data yet"]));
      for (const i of insights) {
        lines.push(csvRow([i.statement, i.sample_size, `+${Math.round(Number(i.lift) * 100)}%`, i.confidence, i.period_start ?? "", i.period_end ?? "", (i.platforms ?? []).join(" ")]));
      }
      lines.push("");
      lines.push(csvRow(["Autocast recommends"]));
      lines.push(csvRow(["Recommendation", "Because", "Confidence", "Status"]));
      if (recs.length === 0) lines.push(csvRow(["None yet"]));
      for (const r of recs) lines.push(csvRow([r.title, r.because, r.confidence, r.status]));
      if (autopilot) {
        lines.push("");
        lines.push(csvRow(["Autopilot"]));
        lines.push(csvRow(["Generation jobs", autopilot.jobs]));
        lines.push(csvRow(["Succeeded", autopilot.succeeded]));
        lines.push(csvRow(["Failed", autopilot.failed]));
        lines.push(csvRow(["Published", autopilot.published]));
        lines.push(csvRow(["Waiting for approval", autopilot.waiting_approval]));
        lines.push(csvRow(["Average generation seconds", autopilot.avg_generation_seconds ?? "Not enough data"]));
        lines.push(csvRow(["Reported cost (cents)", autopilot.cost_cents ?? "Not reported by the provider"]));
      }
      bytes = new TextEncoder().encode(lines.join("\r\n"));
      mime = "text/csv";
      filename = `${base}.csv`;
    } else {
      const summary = METRICS.map(([key, label]) => {
        const current = metricValue(report, key, "current");
        const previous = metricValue(report, key, "previous");
        if (current.value === null) return `${label}: ${current.note}`;
        const delta = change(current.value, previous.value);
        return `${label}: ${display(key, current.value)}${delta ? ` (${delta} vs previous period)` : ""}`;
      });
      const doc: Document = {
        title: `${brand.name} analytics`,
        subtitle: scope,
        sections: [
          { heading: "Overview", paragraphs: summary },
          {
            heading: "Top content",
            paragraphs: (report.top as Json[]).length === 0
              ? ["No videos with numbers yet."]
              : (report.top as Json[]).slice(0, 10).map((v: Json, i: number) =>
                `${i + 1}. ${v.hook || v.title || v.description || "Untitled"} - ${v.views} views, ${v.likes} likes, ${v.shares} shares${v.relative ? `, ${v.relative}x your median` : ""}`),
          },
          {
            heading: "What Autocast learned",
            paragraphs: insights.length === 0
              ? ["Not enough data yet. Autocast needs at least 10 public videos with numbers before it looks for patterns."]
              : insights.map((i) => `${i.statement} Based on ${i.sample_size} posts, +${Math.round(Number(i.lift) * 100)}% median views. Confidence: ${i.confidence}.`),
          },
          {
            heading: "Autocast recommends",
            paragraphs: recs.length === 0 ? ["No recommendations yet."] : recs.map((r) => `${r.title}. Because: ${r.because} (${r.confidence} confidence, ${r.status})`),
          },
          ...(autopilot ? [{
            heading: "Autopilot",
            paragraphs: [
              `${autopilot.jobs} generation jobs: ${autopilot.succeeded} succeeded, ${autopilot.failed} failed.`,
              `${autopilot.published} published, ${autopilot.waiting_approval} waiting for approval.`,
              autopilot.avg_generation_seconds ? `Average generation time: ${autopilot.avg_generation_seconds} seconds.` : "Average generation time: not enough data.",
              autopilot.cost_cents ? `Reported cost: ${(autopilot.cost_cents / 100).toFixed(2)}.` : "Cost: not reported by the provider.",
            ],
          }] : []),
        ],
      };
      bytes = await buildPdf(doc);
      mime = "application/pdf";
      filename = `${base}.pdf`;
    }

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: made, error: madeError } = await admin.rpc("create_artifact", {
      p_user: auth.user.id,
      p_kind: "document",
      p_title: filename,
      p_body: { format: file, filename, source_kind: "analytics", source_title: `${brand.name} analytics`, range: { from: body.from, to: body.to } },
      p_status: "pending",
    });
    if (madeError || !made) throw new Error(`create_artifact: ${madeError?.message ?? "no id"}`);
    const artifactId = made as string;

    const path = `${auth.user.id}/${artifactId}/${filename}`;
    const { error: uploadError } = await admin.storage.from("artifacts").upload(path, bytes, { contentType: mime, upsert: true });
    if (uploadError) throw new Error(`upload: ${uploadError.message}`);

    await admin.rpc("attach_artifact_file", { p_artifact: artifactId, p_path: path, p_mime: mime, p_size: bytes.byteLength });

    return json({ artifact_id: artifactId, filename });
  } catch (error) {
    return fail(error);
  }
});
