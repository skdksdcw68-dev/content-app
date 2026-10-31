import type { Issue } from "./types.ts";

/**
 * Generate -> review -> retry, with the limits that keep a hard scene from
 * becoming an unbounded bill.
 *
 * `generate` and `review` are separate functions on purpose. The reviewer is
 * handed the finished asset and the scene's requirements and nothing about how
 * it was made, and in production it is a different model from the generator: a
 * model grading its own picture is the failure this structure exists to avoid.
 */
export type Verdict = "PASS" | "RETRY" | "ESCALATE";

export interface Review {
  verdict: Verdict;
  problems: string[];
  /** What to change next time, in words the generator's prompt can take. */
  correction: string | null;
  /** 0..1 when the reviewer gives one. */
  score: number | null;
}

export interface Attempt<A> {
  n: number;
  asset: A | null;
  /** Objective failures found before any model was asked. */
  measurable: Issue[];
  review: Review | null;
  costUsd: number;
  error: string | null;
}

export type Outcome<A> =
  | { status: "passed"; asset: A; attempts: Attempt<A>[]; spentUsd: number }
  | { status: "escalate"; reason: string; best: A | null; attempts: Attempt<A>[]; spentUsd: number };

export interface LoopOptions<A> {
  /** Attempts before giving up on this asset. Small on purpose. */
  maxAttempts: number;
  /** Ceiling for everything this loop may spend, dollars. */
  budgetUsd: number;
  /** Lowest score accepted when the reviewer gives one. */
  minScore: number;
  generate(feedback: string | null, attempt: number): Promise<{ asset: A; costUsd: number }>;
  /** Cheap, deterministic checks (size, aspect, duration). Run first; a
   *  failure here never reaches the model reviewer. */
  measure?(asset: A): Issue[];
  review(asset: A, attempt: number): Promise<{ review: Review; costUsd: number }>;
  /** Called after every attempt so progress and spend are persisted even if
   *  the worker dies mid-loop. */
  record?(attempt: Attempt<A>): Promise<void> | void;
  /** True for errors worth another attempt (a rate limit); anything else ends
   *  the loop at once, because retrying a refusal buys the same refusal. */
  retryable?(error: unknown): boolean;
}

export async function reviewLoop<A>(o: LoopOptions<A>): Promise<Outcome<A>> {
  const attempts: Attempt<A>[] = [];
  let spent = 0;
  let feedback: string | null = null;
  let best: A | null = null;

  for (let n = 1; n <= o.maxAttempts; n++) {
    // Never start an attempt we may not be allowed to finish.
    if (spent >= o.budgetUsd) {
      return { status: "escalate", reason: `budget of $${o.budgetUsd} reached`, best, attempts, spentUsd: spent };
    }

    const attempt: Attempt<A> = { n, asset: null, measurable: [], review: null, costUsd: 0, error: null };
    attempts.push(attempt);

    try {
      const made = await o.generate(feedback, n);
      attempt.asset = made.asset;
      attempt.costUsd += made.costUsd;
      spent += made.costUsd;
      best = made.asset;
    } catch (thrown) {
      attempt.error = thrown instanceof Error ? thrown.message : String(thrown);
      await o.record?.(attempt);
      if (o.retryable?.(thrown)) continue;
      return { status: "escalate", reason: `generation failed: ${attempt.error}`, best, attempts, spentUsd: spent };
    }

    attempt.measurable = o.measure?.(attempt.asset!) ?? [];
    const hard = attempt.measurable.filter((i) => i.level === "error");
    if (hard.length > 0) {
      feedback = hard.map((i) => i.message).join("; ");
      await o.record?.(attempt);
      continue;
    }

    if (spent >= o.budgetUsd) {
      await o.record?.(attempt);
      return { status: "escalate", reason: `budget of $${o.budgetUsd} reached before review`, best, attempts, spentUsd: spent };
    }

    const reviewed = await o.review(attempt.asset!, n);
    attempt.review = reviewed.review;
    attempt.costUsd += reviewed.costUsd;
    spent += reviewed.costUsd;
    await o.record?.(attempt);

    const r = reviewed.review;
    // A PASS that carries problems or a low score is not a pass. Approval has
    // to survive its own paperwork.
    const lowScore = r.score !== null && r.score < o.minScore;
    if (r.verdict === "PASS" && r.problems.length === 0 && !lowScore) {
      return { status: "passed", asset: attempt.asset!, attempts, spentUsd: spent };
    }
    if (r.verdict === "ESCALATE") {
      return { status: "escalate", reason: r.problems.join("; ") || "reviewer escalated", best, attempts, spentUsd: spent };
    }
    feedback = [r.correction, ...r.problems].filter(Boolean).join(" | ") || "improve on the previous attempt";
  }

  return {
    status: "escalate",
    reason: `${o.maxAttempts} attempts did not pass`,
    best,
    attempts,
    spentUsd: spent,
  };
}

/**
 * The reviewer's reply, parsed defensively. A reply that cannot be read is an
 * ESCALATE, never a PASS: silence must not approve anything.
 */
export function parseReview(raw: unknown): Review {
  const o = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  const verdict = o && ["PASS", "RETRY", "ESCALATE"].includes(String(o.verdict)) ? (String(o.verdict) as Verdict) : null;
  if (!o || !verdict) {
    return { verdict: "ESCALATE", problems: ["the reviewer's answer could not be read"], correction: null, score: null };
  }
  const problems = Array.isArray(o.problems) ? o.problems.map((p) => String(p).trim()).filter(Boolean) : [];
  const score = typeof o.score === "number" && o.score >= 0 && o.score <= 1 ? o.score : null;
  const correction = typeof o.correction === "string" && o.correction.trim() ? o.correction.trim() : null;
  return { verdict, problems, correction, score };
}
