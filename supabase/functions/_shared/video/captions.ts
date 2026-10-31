import type { Aspect, Issue, WordTiming } from "./types.ts";
import { FRAME } from "./types.ts";

/**
 * Word timings -> burned-in captions, and the checks that keep them on screen.
 *
 * Timings are the voice's own. Nothing here guesses when a word is said.
 */

export interface CaptionTheme {
  fontName: string;
  /** Fraction of frame height. */
  sizeRatio: number;
  /** ASS colours are &HBBGGRR&. */
  primary: string;
  highlight: string;
  outline: string;
  /** Distance from the bottom edge, fraction of frame height. Vertical video
   *  keeps clear of the platforms' own buttons and caption bar. */
  bottomRatio: number;
  /** Words per on-screen group. */
  wordsPerGroup: number;
  uppercase: boolean;
}

export const THEMES: Record<string, CaptionTheme> = {
  clean: { fontName: "Arial", sizeRatio: 0.036, primary: "&HFFFFFF&", highlight: "&H00E0FF&", outline: "&H000000&", bottomRatio: 0.2, wordsPerGroup: 4, uppercase: false },
  bold: { fontName: "Arial", sizeRatio: 0.048, primary: "&HFFFFFF&", highlight: "&H00D5FF&", outline: "&H000000&", bottomRatio: 0.24, wordsPerGroup: 3, uppercase: true },
  horror: { fontName: "Arial", sizeRatio: 0.042, primary: "&HE6E6E6&", highlight: "&H2020E0&", outline: "&H000000&", bottomRatio: 0.22, wordsPerGroup: 3, uppercase: true },
};

export interface CaptionGroup {
  words: WordTiming[];
  startS: number;
  endS: number;
}

/** Splits at sentence ends first, then at the group size, so a caption never
 *  straddles a full stop. */
export function groupWords(words: WordTiming[], perGroup: number): CaptionGroup[] {
  const groups: CaptionGroup[] = [];
  let current: WordTiming[] = [];
  const flush = () => {
    if (current.length === 0) return;
    groups.push({ words: current, startS: current[0]!.startS, endS: current[current.length - 1]!.endS });
    current = [];
  };
  for (const w of words) {
    current.push(w);
    if (current.length >= perGroup || /[.!?]$/.test(w.word)) flush();
  }
  flush();
  return groups;
}

/** ASS timestamps are h:mm:ss.cc. */
function stamp(s: number): string {
  const cs = Math.max(0, Math.round(s * 100));
  const h = Math.floor(cs / 360000);
  const m = Math.floor((cs % 360000) / 6000);
  const sec = Math.floor((cs % 6000) / 100);
  return `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}.${String(cs % 100).padStart(2, "0")}`;
}

const esc = (w: string): string => w.replace(/[{}\\]/g, "").replace(/\n/g, " ");

/**
 * One Dialogue line per spoken word: the whole group is shown, with the word
 * being said in the highlight colour (and the ones in `emphasis` kept bold).
 * Lines meet end-to-start so there is no flicker between words.
 */
export function toAss(
  words: WordTiming[],
  opts: { aspect: Aspect; theme?: CaptionTheme; emphasis?: string[] },
): string {
  const theme = opts.theme ?? THEMES.clean!;
  const { width, height } = FRAME[opts.aspect];
  const size = Math.round(height * theme.sizeRatio);
  const marginV = Math.round(height * theme.bottomRatio);
  const marginX = Math.round(width * 0.06);
  const emphasis = new Set((opts.emphasis ?? []).map((e) => e.toLowerCase().replace(/[^\p{L}\p{N}']/gu, "")));
  const groups = groupWords(words, theme.wordsPerGroup);

  const lines: string[] = [
    "[Script Info]",
    "ScriptType: v4.00+",
    `PlayResX: ${width}`,
    `PlayResY: ${height}`,
    "WrapStyle: 0",
    "ScaledBorderAndShadow: yes",
    "",
    "[V4+ Styles]",
    "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
    `Style: Cap,${theme.fontName},${size},${theme.primary},${theme.primary},${theme.outline},&H80000000&,-1,0,0,0,100,100,0,0,1,${Math.max(2, Math.round(size / 14))},0,2,${marginX},${marginX},${marginV},1`,
    "",
    "[Events]",
    "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
  ];

  for (const g of groups) {
    g.words.forEach((active, ai) => {
      const start = active.startS;
      // Hold the line until the next word starts (or the group ends), so the
      // caption does not blink off in the gap between words.
      const next = g.words[ai + 1];
      const end = next ? next.startS : Math.max(active.endS, g.endS);
      const body = g.words
        .map((w, wi) => {
          const shown = esc(theme.uppercase ? w.word.toUpperCase() : w.word);
          const bold = emphasis.has(w.word.toLowerCase().replace(/[^\p{L}\p{N}']/gu, ""));
          if (wi === ai) return `{\\c${theme.highlight}\\b1}${shown}{\\c${theme.primary}\\b${bold ? 1 : 0}}`;
          return bold ? `{\\b1}${shown}{\\b0}` : shown;
        })
        .join(" ");
      lines.push(`Dialogue: 0,${stamp(start)},${stamp(end)},Cap,,0,0,0,,${body}`);
    });
  }
  return lines.join("\n") + "\n";
}

/**
 * Objective checks on timing and placement, run before anything is rendered.
 * Returns errors for what would ship broken and warnings for what is merely
 * poor.
 */
export function checkCaptions(
  words: WordTiming[],
  opts: { aspect: Aspect; durationS: number; theme?: CaptionTheme },
): Issue[] {
  const issues: Issue[] = [];
  const theme = opts.theme ?? THEMES.clean!;
  const { width, height } = FRAME[opts.aspect];

  if (words.length === 0) {
    return [{ path: "captions", message: "no words to caption", level: "error" }];
  }

  let prevEnd = 0;
  words.forEach((w, i) => {
    const at = `captions[${i}]`;
    if (!(w.endS > w.startS)) issues.push({ path: at, message: `"${w.word}" has no duration`, level: "error" });
    if (w.startS < prevEnd - 0.05) issues.push({ path: at, message: `"${w.word}" starts before the previous word ends`, level: "error" });
    if (w.endS > opts.durationS + 0.05) issues.push({ path: at, message: `"${w.word}" ends after the video does`, level: "error" });
    prevEnd = Math.max(prevEnd, w.endS);
  });

  // Rendered width of the widest group against the frame, at a conservative
  // average glyph width of 0.58 em (bold caps run wider than lower case).
  const size = height * theme.sizeRatio;
  const glyph = size * (theme.uppercase ? 0.68 : 0.58);
  const usable = width * (1 - 0.12);
  for (const g of groupWords(words, theme.wordsPerGroup)) {
    const chars = g.words.map((w) => w.word).join(" ").length;
    if (chars * glyph > usable) {
      issues.push({
        path: `captions@${g.startS.toFixed(2)}s`,
        message: `"${g.words.map((w) => w.word).join(" ")}" is wider than the safe area; it will wrap to two lines`,
        level: "warning",
      });
    }
  }

  // Two wrapped lines must still clear the top of the bottom margin.
  const blockTop = height * theme.bottomRatio + size * 2.6;
  if (blockTop > height * 0.5) issues.push({ path: "theme", message: "caption block reaches past the middle of the frame", level: "error" });
  return issues;
}

/**
 * ElevenLabs' `with-timestamps` answers per character. Words are rebuilt by
 * splitting on whitespace, which keeps the provider's own timing for every
 * letter instead of spreading a word's span evenly.
 */
export function wordsFromCharacters(
  characters: string[],
  starts: number[],
  ends: number[],
): WordTiming[] {
  const words: WordTiming[] = [];
  let word = "";
  let start = 0;
  let end = 0;
  const push = () => {
    if (word) words.push({ word, startS: start, endS: end });
    word = "";
  };
  characters.forEach((ch, i) => {
    if (/\s/.test(ch)) {
      push();
      return;
    }
    if (!word) start = starts[i] ?? end;
    word += ch;
    end = ends[i] ?? start;
  });
  push();
  return words;
}
