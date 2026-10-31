/**
 * `/story <style> [seconds] [--no-voice] <topic>` typed into the chat.
 *
 * A typed command rather than a guess from free text: it starts a job that
 * spends money, and a message router that misreads "I love scary stories" as a
 * request is how somebody gets billed for a video they did not ask for.
 */
export type StoryCommand =
  | { kind: "help" }
  | { kind: "error"; message: string }
  | { kind: "start"; styleSlug: string; topic: string; durationS?: number; narration?: boolean };

export const MIN_SECONDS = 15;
export const MAX_SECONDS = 90;

export function parseStoryCommand(text: string): StoryCommand | null {
  const m = /^\s*\/story\b(.*)$/is.exec(text);
  if (!m) return null;
  const rest = m[1]!.trim();
  if (!rest || /^(help|list|\?)$/i.test(rest)) return { kind: "help" };

  const words = rest.split(/\s+/);
  const styleSlug = words.shift()!.toLowerCase().replace(/[^a-z0-9-]/g, "");
  if (!styleSlug) return { kind: "help" };

  let durationS: number | undefined;
  let narration: boolean | undefined;
  // Options may come straight after the style; the topic is everything after.
  while (words.length > 0) {
    const w = words[0]!.toLowerCase();
    const secs = /^(\d{1,3})\s*s?(ec(onds?)?)?$/.exec(w);
    if (secs && durationS === undefined) {
      durationS = Number(secs[1]);
      words.shift();
    } else if (w === "--no-voice" || w === "--novoice" || w === "--silent") {
      narration = false;
      words.shift();
    } else if (w === "--voice") {
      narration = true;
      words.shift();
    } else break;
  }

  const topic = words.join(" ").trim();
  if (!topic) return { kind: "error", message: "Tell me what the story is about, e.g. /story scary 60 footsteps in an empty house" };
  if (durationS !== undefined && (durationS < MIN_SECONDS || durationS > MAX_SECONDS)) {
    return { kind: "error", message: `Stories can be ${MIN_SECONDS} to ${MAX_SECONDS} seconds. You asked for ${durationS}.` };
  }
  return {
    kind: "start",
    styleSlug,
    topic: topic.slice(0, 400),
    ...(durationS !== undefined ? { durationS } : {}),
    ...(narration !== undefined ? { narration } : {}),
  };
}
