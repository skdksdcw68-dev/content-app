/**
 * Answers that look things up on the web first, streamed as they are written.
 *
 * Abel, 3 Nov 2026, with a screen recording side by side: ChatGPT answered
 * "could you tell me what games are available today" with tonight's matches in
 * his time zone, its first words six seconds after he sent it and the whole
 * answer in nine. Ours started a five-minute research report about Google
 * Doodles. This is the ChatGPT way: one call that searches and then writes,
 * "Searching the web" while it searches, the sources under the answer.
 */

/** A page a web answer used, for the Sources sheet under it. */
export interface WebSource {
  url: string;
  title: string;
  site: string;
}

/**
 * Where they are and what time it is there. Without it "what's on tonight" is
 * answered for a server in the US: ChatGPT gave Abel kick-off times in
 * Ethiopian time, and so must this.
 */
export function whereTheyAre(timezone: unknown, region: unknown): { location: Record<string, string> | null; now: string } {
  const country = typeof region === "string" && /^[A-Z]{2}$/.test(region) ? region : null;
  let zone: string | null = null;
  let now = `Now: ${new Date().toUTCString()}. Their time zone is not known.`;
  if (typeof timezone === "string" && timezone.length < 64) {
    try {
      const date = new Date();
      const told = new Intl.DateTimeFormat("en-GB", { timeZone: timezone, dateStyle: "full", timeStyle: "short" })
        .format(date);
      // The offset itself, spelled out: given only the zone's name, the model
      // put Tuesday's 12:45 ET kick-off at 5:45 PM in Addis -- three hours out.
      const offset = new Intl.DateTimeFormat("en-GB", { timeZone: timezone, timeZoneName: "shortOffset" })
        .formatToParts(date).find((part) => part.type === "timeZoneName")?.value.replace("GMT", "UTC") ?? "";
      const utc = date.toISOString().slice(11, 16);
      zone = timezone;
      now = `Now, where they are: ${told} (${timezone}, ${offset || "UTC"}). In UTC it is ${utc}. ` +
        "Work every time out through UTC -- a source's time in its own zone, to UTC, then to theirs -- " +
        "silently: show only their local time, never the working or UTC.";
    } catch {
      // Not a zone this runtime knows: UTC, and no zone sent on.
    }
  }
  const location = zone || country
    ? { type: "approximate", ...(country ? { country } : {}), ...(zone ? { timezone: zone } : {}) }
    : null;
  return { location, now };
}

/** The citations OpenAI writes into searched text -- " ([site](url))", or a bare
 *  link it tagged, or the empty "()" one sometimes leaves -- which the app shows
 *  under the answer instead. */
export const CITATION =
  /[ \t]*\(\[[^\]\n]*\]\([^)\s]*\)\)|[ \t]*\[[^\]\n]*\]\([^)\s]*utm_source=openai[^)\s]*\)|[ \t]*\([ \t]*\)/g;

/**
 * Where in streamed text a citation may have begun without finishing yet, so
 * the text from there waits for the rest of it. Everything before is safe to
 * show. A real link the answer means to keep waits only until it is complete.
 */
export function heldFrom(text: string): number {
  let cut = text.length;
  const bracket = text.lastIndexOf("[");
  if (bracket !== -1) {
    const tail = text.slice(bracket);
    const open = /^\[[^\]\n]*(\](\([^)\s]*)?)?$/.test(tail);
    const linked = /^\[[^\]\n]*\]\([^)\s]*\)$/.test(tail);
    const wrapped = text[bracket - 1] === "(";
    if (open || (linked && wrapped)) {
      // Back over the "(" and the space that open " ([site](url))".
      let from = wrapped ? bracket - 1 : bracket;
      while (from > 0 && (text[from - 1] === " " || text[from - 1] === "\t")) from--;
      cut = from;
    }
  }
  // A "(" at the very end could be the start of one -- and so could the next
  // piece, after spaces that show nothing yet. Sent early, a space stays when
  // the citation after it is taken out: "Bratislava ." (found by feeding the
  // stream in random pieces). Line breaks wait too, so a block's end ("\n\n")
  // is seen whole even when it arrives in two pieces.
  const opening = text.search(/[ \t\n]*\(?$/);
  if (opening !== -1) cut = Math.min(cut, opening);
  return cut;
}

/** The pages one citation names -- one, or none for an empty "()". */
function citedIn(citation: string): WebSource[] {
  const pages: WebSource[] = [];
  for (const link of citation.matchAll(/\[[^\]\n]*\]\(([^)\s]*)\)/g)) {
    const page = webSource(link[1], null);
    if (page) pages.push(page);
  }
  return pages;
}

/**
 * ChatGPT's source chip: the first site's name, "+2" for the others, written
 * as a link the app draws as a small grey pill -- "[livescore.com +1](cite:
 * https://...)". An older app, which knows no chips, shows a plain link.
 */
export function chipFor(pages: WebSource[]): string {
  const sites = [...new Set(pages.map((page) => page.site))];
  const label = sites.length > 1 ? `${sites[0]} +${sites.length - 1}` : sites[0];
  return `[${label}](cite:${pages[0].url})`;
}

/**
 * Turns streamed text that is safe to show into what is shown: the citations
 * out of the sentences, and one chip where each block ends -- at the end of a
 * paragraph, or on a line of its own after a list or a table, which is where
 * ChatGPT put "LiveTV.Africa +1" in Abel's recording. `written` is everything
 * already shown, to know what kind of block a break closes.
 */
export function chipper(): (ready: string, written: string, final: boolean) => string {
  let cited: WebSource[] = [];
  const pattern = new RegExp(`${CITATION.source}|\\n\\n`, "g");

  const chipAfter = (before: string): string => {
    if (cited.length === 0) return "";
    const chip = chipFor(cited);
    cited = [];
    const line = before.slice(before.lastIndexOf("\n") + 1).trim();
    return /^(\||[-*•] |\d+\. )/.test(line) ? `\n\n${chip}` : ` ${chip}`;
  };

  return (ready, written, final) => {
    let out = "";
    let last = 0;
    for (const match of ready.matchAll(pattern)) {
      out += ready.slice(last, match.index);
      last = (match.index ?? 0) + match[0].length;
      if (match[0] === "\n\n") {
        out += chipAfter(written + out) + "\n\n";
      } else {
        for (const page of citedIn(match[0])) {
          if (!cited.some((known) => known.url === page.url)) cited.push(page);
        }
      }
    }
    out += ready.slice(last);
    if (final) out += chipAfter(written + out);
    return out;
  };
}

/** One cited page, tidied: the tracking tag off, the site named. Null for
 *  anything that is not a web address. */
export function webSource(url: unknown, title: unknown): WebSource | null {
  if (typeof url !== "string") return null;
  try {
    const parsed = new URL(url);
    if (!/^https?:$/.test(parsed.protocol)) return null;
    parsed.searchParams.delete("utm_source");
    const site = parsed.hostname.replace(/^www\./, "");
    const named = typeof title === "string" && title.trim() ? title.trim() : site;
    return { url: parsed.toString(), title: named.slice(0, 160), site };
  } catch {
    return null;
  }
}

/** A chat-completions turn, in the shape the Responses API reads. */
export function asResponsesTurn(turn: { role: string; content: unknown }): Record<string, unknown> {
  if (!Array.isArray(turn.content)) return { role: turn.role, content: String(turn.content ?? "") };
  return {
    role: turn.role,
    content: (turn.content as Array<Record<string, any>>).map((part) =>
      part.type === "image_url"
        ? { type: "input_image", image_url: part.image_url?.url, detail: part.image_url?.detail ?? "auto" }
        : { type: turn.role === "assistant" ? "output_text" : "input_text", text: String(part.text ?? "") }
    ),
  };
}

/**
 * How the answer should read, added to the reply's own rules. `always` when the
 * search is forced; `maybe` when the model decides for itself whether to look.
 */
export function webRules(now: string, mode: "always" | "maybe" = "always"): string {
  if (mode === "maybe") {
    return [
      now,
      "YOU CAN SEARCH THE WEB. Your own knowledge is old -- it stops in 2024 or 2025 -- and the world has",
      "moved on. Search before you answer whenever a good answer depends on anything current: today, this",
      "week or now; what is trending (sounds, formats, challenges, memes, topics); news, events, games,",
      "prices, releases; a specific product, app, company or person; or content built on any of these.",
      "Never give something from memory as today's news or today's trends. Do not search for small talk,",
      "for their own account (ACCOUNT has it), or for advice that does not depend on today.",
      "When you did search, answer from what you found the way ChatGPT does: the answer first, then only",
      "what helps them use it. Do not say in the text which site said what: the app shows the sources",
      "under the answer.",
    ].join("\n");
  }
  return [
    "YOU SEARCHED THE WEB FOR THIS MESSAGE. Answer from what you found, the way ChatGPT answers with",
    "search: the answer first, then only what helps them use it -- a small table when several items share",
    "the same details (time, price, where), a short list, your top picks when they would want them. Keep it",
    "to about one phone screen unless they asked for detail. No report: no Summary, Next steps or Still",
    "unknown sections, no advice to check other sources.",
    now,
    "Do not say in the text which site said what (\"CBS lists...\"): the app shows the sources under the",
    "answer. If what you found does not answer it, say so in one sentence and give what you did find.",
    "When the question could mean more than one thing, answer the ONE a person in their place most likely",
    "means -- where they live shapes that -- and only that one; then end with one short question offering",
    "the others.",
  ].join("\n");
}

export interface WebAnswer {
  /** Everything shown, citations taken out. Empty when nothing came back. */
  text: string;
  sources: WebSource[];
  usage: { prompt_tokens?: number; completion_tokens?: number; prompt_tokens_details?: { cached_tokens?: number } } | null;
  /** How many web searches it ran -- each is billed on top of the tokens. */
  searches: number;
  /** The model that wrote it: `model`, or `fallbackModel` when that was refused. */
  model: string;
}

/**
 * Searches, then writes, streaming the words out through `onText` as they come
 * -- minus the citations, which come back as `sources`. `onSearching` is called
 * once, when OpenAI has taken the call and the (forced) search has begun.
 *
 * Returns null when the call could not be made at all, so the caller can still
 * answer without the web.
 */
export async function answerFromTheWeb(options: {
  apiKey: string;
  model: string;
  instructions: string;
  input: Array<Record<string, unknown>>;
  location: Record<string, string> | null;
  /** For a reasoning model: how hard it thinks before it writes. */
  effort?: "none" | "low" | "medium";
  /** `required` searches every time (the router said it needs the web);
   *  `auto` lets the model decide, the way ChatGPT does. */
  search?: "required" | "auto";
  /** Tried when `model` is refused -- an older model that still answers when
   *  the account has no credit for the newer ones. */
  fallbackModel?: string;
  /** Called when a search begins: at once when it is required, otherwise when
   *  the model starts one. Never called for an answer that did not search. */
  onSearching: () => void;
  /** After each search, every site read so far, so their logos can show while
   *  it keeps working -- ChatGPT's "Searching websites" with the icons. */
  onRead?: (sites: string[]) => void;
  onText: (text: string) => void;
}): Promise<WebAnswer | null> {
  const call = (model: string, effort: typeof options.effort) =>
    fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { Authorization: `Bearer ${options.apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model,
        stream: true,
        tools: [{ type: "web_search", ...(options.location ? { user_location: options.location } : {}) }],
        // Required when the router decided this needs looking up -- an answer
        // from memory about "today" is exactly what this replaces. Otherwise the
        // model looks things up when it judges it needs to.
        tool_choice: options.search ?? "required",
        // Every page the search read, not only the ones the text cites: an
        // answer can cite nothing and still have been built from five sites.
        include: ["web_search_call.action.sources"],
        ...(effort ? { reasoning: { effort } } : {}),
        instructions: options.instructions,
        input: options.input,
      }),
    }).catch((error) => {
      console.error("web answer", error instanceof Error ? error.message : error);
      return null;
    });

  let model = options.model;
  let response = await call(model, options.effort);
  // Refused (no credit for the newer models, as on 3 Nov 2026): the fallback
  // model, which takes no reasoning effort, before giving up.
  if (response && !response.ok && options.fallbackModel && options.fallbackModel !== model) {
    console.warn("web answer: falling back", model, response.status);
    await response.body?.cancel().catch(() => {});
    model = options.fallbackModel;
    response = await call(model, undefined);
  }

  if (!response) return null;
  if (!response.ok || !response.body) {
    console.error("web answer", response.status, (await response.text().catch(() => "")).slice(0, 400));
    return null;
  }

  // A forced search is under way the moment the call is taken: OpenAI reports
  // it only when the written answer arrives with it, in one burst about four
  // seconds later -- too late to be worth saying. One the model chooses is
  // said when it starts.
  const forced = (options.search ?? "required") === "required";
  let searching = forced;
  if (forced) options.onSearching();
  let searches = 0;

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  // Text held back while a citation may still be arriving.
  let held = "";
  let text = "";
  let usage: WebAnswer["usage"] = null;
  const sources: WebSource[] = [];
  // Pages the search read without the text citing them, listed after the cited ones.
  const read: WebSource[] = [];

  const cite = (url: unknown, title: unknown) => {
    const source = webSource(url, title);
    if (source && !sources.some((known) => known.url === source.url)) sources.push(source);
  };
  const shape = chipper();
  const pass = (final: boolean) => {
    const cut = final ? held.length : heldFrom(held);
    const ready = shape(held.slice(0, cut), text, final);
    held = held.slice(cut);
    if (ready) {
      text += ready;
      options.onText(ready);
    }
  };

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    // Frames are separated by a blank line; a partial one stays in the buffer
    // until the rest of it arrives.
    const frames = buffer.split("\n\n");
    buffer = frames.pop() ?? "";

    for (const frame of frames) {
      const line = frame.split("\n").find((part) => part.startsWith("data: "));
      if (!line) continue;
      let event: Record<string, any>;
      try {
        event = JSON.parse(line.slice(6));
      } catch {
        continue;
      }
      switch (event?.type) {
        case "response.output_item.added":
          if (event.item?.type === "web_search_call" && !searching) {
            searching = true;
            options.onSearching();
          }
          break;
        case "response.output_item.done":
          // A finished search, with every page it read.
          if (event.item?.type === "web_search_call") {
            searches += 1;
            const before = read.length;
            for (const page of (event.item.action?.sources ?? []) as Array<Record<string, any>>) {
              const source = webSource(page.url, page.title);
              if (source && !read.some((known) => known.url === source.url)) read.push(source);
            }
            if (read.length > before) options.onRead?.([...new Set(read.map((page) => page.site))]);
          }
          break;
        case "response.output_text.delta":
          if (typeof event.delta === "string") {
            held += event.delta;
            pass(false);
          }
          break;
        case "response.output_text.annotation.added":
          if (event.annotation?.type === "url_citation") cite(event.annotation.url, event.annotation.title);
          break;
        case "response.completed": {
          const used = event.response?.usage;
          usage = used
            ? {
              prompt_tokens: used.input_tokens,
              completion_tokens: used.output_tokens,
              prompt_tokens_details: { cached_tokens: used.input_tokens_details?.cached_tokens ?? 0 },
            }
            : null;
          // The finished answer's own citations, in case any were not
          // announced on the way.
          for (const item of (event.response?.output ?? []) as Array<Record<string, any>>) {
            for (const part of (item.content ?? []) as Array<Record<string, any>>) {
              for (const note of (part.annotations ?? []) as Array<Record<string, any>>) {
                if (note.type === "url_citation") cite(note.url, note.title);
              }
            }
          }
          break;
        }
        case "response.failed":
        case "error":
          console.error("web answer", JSON.stringify(event).slice(0, 400));
          break;
      }
    }
  }
  pass(true);

  // What the answer cited comes first, then whatever else the search read.
  for (const page of read) {
    if (!sources.some((known) => known.url === page.url)) sources.push(page);
  }
  return { text, sources: sources.slice(0, 12), usage, searches, model };
}
