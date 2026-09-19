/**
 * The Brand page's questionnaire, as the writers read it.
 *
 * `brands.profile` holds each answer with its question title and option
 * labels, so this needs no copy of the question set: a question added in the
 * app shows up here without a deploy.
 *
 * These are PREFERENCES -- how to write -- and are deliberately printed apart
 * from FACTS. "Main goal: downloads" says what the posts are for, not
 * something true about the product, and mixing the two is how a plan ends up
 * announcing things that are not so.
 */

type Answer = { title?: string; answers?: unknown };

export function preferenceLines(profile: unknown): string[] {
  if (!profile || typeof profile !== "object") return [];
  const lines: string[] = [];
  for (const value of Object.values(profile as Record<string, Answer>)) {
    const title = typeof value?.title === "string" ? value.title.trim() : "";
    const answers = Array.isArray(value?.answers)
      ? value.answers.filter((a): a is string => typeof a === "string" && a.trim().length > 0).map((a) => a.trim())
      : [];
    if (title && answers.length) lines.push(`${title}: ${answers.join(", ")}`);
  }
  return lines;
}

/** The block to put after FACTS, or nothing when there are no answers. */
export function preferenceBlock(profile: unknown): string {
  const lines = preferenceLines(profile);
  if (!lines.length) return "";
  return [
    "\nPREFERENCES (how the owner wants posts written -- follow them, but they are not facts about the product and must never be stated as claims):",
    ...lines.map((line) => `- ${line}`),
  ].join("\n");
}
