/**
 * Real files from structured content: DOCX, PDF and ZIP.
 *
 * "Export it as a DOCX" is not satisfied by markdown with a .docx extension.
 * Word refuses it, Pages shows it as text, and the person concludes the export
 * is broken -- correctly. So each format is built properly:
 *
 *   DOCX  a zip of WordprocessingML parts, with real heading styles, real
 *         bullet and numbered lists, bold and italic, tables with a shaded
 *         header row, and page numbers.
 *   PDF   laid out with pdf-lib: wrapped lines with bold and italic inside a
 *         line, bullets, numbered steps, tables, quotes, and page numbers.
 *   ZIP   fflate, with a manifest, because a package somebody cannot see into
 *         before opening is a package they will not trust.
 *
 * All three take the same input -- a title and sections of paragraphs -- and a
 * paragraph may be written in markdown (## headings, **bold**, - bullets,
 * 1. steps, | tables |, > quotes), which is read into blocks. Abel, 2 Nov 2026:
 * "the export thing is looking a bit messy". It was a wall of paragraphs with
 * every symbol stripped out and no structure left.
 */

import { strToU8, zipSync } from "https://esm.sh/fflate@0.8.2";
import { PDFDocument, type PDFFont, type PDFPage, rgb, StandardFonts } from "https://esm.sh/pdf-lib@1.17.1";

export interface Section {
  heading?: string;
  paragraphs: string[];
}

export interface Document {
  title: string;
  subtitle?: string;
  sections: Section[];
}

// ---------------------------------------------------------------- markdown

/** A stretch of text in one style. */
export interface Run {
  text: string;
  bold?: boolean;
  italic?: boolean;
  code?: boolean;
}

export type Block =
  | { type: "heading"; level: number; runs: Run[] }
  | { type: "paragraph"; runs: Run[] }
  | { type: "bullets"; items: Run[][] }
  | { type: "numbered"; start: number; items: Run[][] }
  | { type: "quote"; runs: Run[] }
  | { type: "code"; text: string }
  | { type: "rule" }
  | { type: "table"; header: Run[][]; rows: Run[][][] };

/** **bold**, *italic*, `code` and [label](url) read into runs. A marker that is
 *  never closed is bold to the end; a lone `*` is a character. */
export function parseRuns(text: string): Run[] {
  const runs: Run[] = [];
  const chars = Array.from(text);
  let buffer = "";
  let bold = false;
  let italic = false;

  const flush = (code = false) => {
    if (!buffer) return;
    runs.push({ text: buffer, bold, italic, code });
    buffer = "";
  };

  for (let i = 0; i < chars.length; i++) {
    const c = chars[i];

    if (c === "`") {
      const end = chars.indexOf("`", i + 1);
      if (end > i) {
        flush();
        buffer = chars.slice(i + 1, end).join("");
        flush(true);
        i = end;
        continue;
      }
    }

    if (c === "*" && chars[i + 1] === "*") {
      flush();
      bold = !bold;
      i += 1;
      continue;
    }

    if (c === "*") {
      const next = chars[i + 1];
      const previous = chars[i - 1];
      if (italic) {
        if (previous !== undefined && !/\s/.test(previous)) {
          flush();
          italic = false;
          continue;
        }
      } else if (next !== undefined && !/\s/.test(next) && chars.indexOf("*", i + 1) > -1) {
        flush();
        italic = true;
        continue;
      }
    }

    if (c === "[") {
      const close = chars.indexOf("]", i + 1);
      if (close > i && chars[close + 1] === "(") {
        const paren = chars.indexOf(")", close + 2);
        if (paren > close) {
          buffer += `${chars.slice(i + 1, close).join("")} (${chars.slice(close + 2, paren).join("")})`;
          i = paren;
          continue;
        }
      }
    }

    buffer += c;
  }
  flush();
  return runs;
}

function cellsOf(line: string): string[] {
  let text = line.trim();
  if (text.startsWith("|")) text = text.slice(1);
  if (text.endsWith("|")) text = text.slice(0, -1);
  return text.split("|").map((cell) => cell.trim());
}

function isSeparator(line: string | undefined): boolean {
  if (line === undefined || !line.includes("-")) return false;
  const row = cellsOf(line);
  return row.length > 0 && row.every((cell) => /^:?-+:?$/.test(cell));
}

/** The same reading the app does (`ChatMarkdown.blocks`): headings, lists with
 *  their numbers kept, tables, quotes, code and rules. */
export function parseBlocks(source: string): Block[] {
  const lines = source.replace(/\r\n/g, "\n").split("\n");
  const blocks: Block[] = [];
  let paragraph: string[] = [];
  let bullets: string[] = [];
  let numbered: string[] = [];
  let numberedStart = 1;
  let quote: string[] = [];
  let code: string[] | null = null;

  const flushParagraph = () => {
    if (paragraph.length) blocks.push({ type: "paragraph", runs: parseRuns(paragraph.join(" ")) });
    paragraph = [];
  };
  const flushBullets = () => {
    if (bullets.length) blocks.push({ type: "bullets", items: bullets.map(parseRuns) });
    bullets = [];
  };
  const flushNumbered = () => {
    if (numbered.length) blocks.push({ type: "numbered", start: numberedStart, items: numbered.map(parseRuns) });
    numbered = [];
  };
  const flushQuote = () => {
    if (quote.length) blocks.push({ type: "quote", runs: parseRuns(quote.join(" ")) });
    quote = [];
  };
  const flushAll = () => {
    flushParagraph();
    flushBullets();
    flushNumbered();
    flushQuote();
  };

  for (let index = 0; index < lines.length; index++) {
    const raw = lines[index];
    const line = raw.trim();

    if (code !== null) {
      if (line.startsWith("```")) {
        blocks.push({ type: "code", text: code.join("\n") });
        code = null;
      } else {
        code.push(raw);
      }
      continue;
    }
    if (line.startsWith("```")) {
      flushAll();
      code = [];
      continue;
    }
    if (!line) {
      flushAll();
      continue;
    }

    if (line.includes("|") && isSeparator(lines[index + 1])) {
      flushAll();
      const header = cellsOf(line).map(parseRuns);
      const rows: Run[][][] = [];
      let next = index + 2;
      while (next < lines.length && lines[next].trim() && lines[next].includes("|")) {
        rows.push(cellsOf(lines[next]).map(parseRuns));
        next += 1;
      }
      blocks.push({ type: "table", header, rows });
      index = next - 1;
      continue;
    }

    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      flushAll();
      blocks.push({ type: "heading", level: heading[1].length, runs: parseRuns(heading[2]) });
      continue;
    }

    if (/^([-*_])(\s*\1){2,}$/.test(line)) {
      flushAll();
      blocks.push({ type: "rule" });
      continue;
    }

    if (line.startsWith(">")) {
      flushParagraph();
      flushBullets();
      flushNumbered();
      quote.push(line.replace(/^>\s?/, ""));
      continue;
    }

    const bullet = /^[-*•]\s+(.*)$/.exec(line);
    if (bullet) {
      flushParagraph();
      flushNumbered();
      flushQuote();
      bullets.push(bullet[1]);
      continue;
    }

    const step = /^(\d{1,3})[.)]\s+(.*)$/.exec(line);
    if (step) {
      flushParagraph();
      flushBullets();
      flushQuote();
      if (numbered.length === 0) numberedStart = Number(step[1]);
      numbered.push(step[2]);
      continue;
    }

    const indented = /^\s/.test(raw);
    if (indented && bullets.length) {
      bullets[bullets.length - 1] += ` ${line}`;
      continue;
    }
    if (indented && numbered.length) {
      numbered[numbered.length - 1] += ` ${line}`;
      continue;
    }

    flushBullets();
    flushNumbered();
    flushQuote();
    paragraph.push(line);
  }
  if (code !== null) blocks.push({ type: "code", text: (code as string[]).join("\n") });
  flushAll();
  return blocks;
}

// --------------------------------------------------------------------- DOCX

/** XML-escapes text. A stray ampersand in a research finding is enough to make
 *  Word declare the whole file corrupt. */
function esc(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    // Characters XML 1.0 forbids outright. Models occasionally emit them.
    // deno-lint-ignore no-control-regex
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, "");
}

interface ParagraphOptions {
  style?: string;
  numId?: number;
  before?: number;
  after?: number;
  left?: number;
  hanging?: number;
  keepNext?: boolean;
  bar?: boolean;
  /** A line under the paragraph: a horizontal rule. */
  rule?: boolean;
  shade?: string;
  color?: string;
  size?: number;
}

function runXml(run: Run, options: ParagraphOptions): string {
  const props = [
    run.code ? `<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/>` : "",
    run.bold ? "<w:b/>" : "",
    run.italic ? "<w:i/>" : "",
    options.color ? `<w:color w:val="${options.color}"/>` : "",
    options.size ? `<w:sz w:val="${options.size}"/>` : "",
    run.code ? `<w:shd w:val="clear" w:color="auto" w:fill="F1F3F5"/>` : "",
  ].join("");
  return `<w:r>${props ? `<w:rPr>${props}</w:rPr>` : ""}<w:t xml:space="preserve">${esc(run.text)}</w:t></w:r>`;
}

/** Children of a paragraph's properties are a sequence, and Word holds them to
 *  its order: style, keep, numbering, border, shading, spacing, indent. */
function para(runs: Run[], options: ParagraphOptions = {}): string {
  const spacing = options.before !== undefined || options.after !== undefined
    ? `<w:spacing${options.before !== undefined ? ` w:before="${options.before}"` : ""}${
      options.after !== undefined ? ` w:after="${options.after}"` : ""
    }/>`
    : "";
  const props = [
    options.style ? `<w:pStyle w:val="${options.style}"/>` : "",
    options.keepNext ? "<w:keepNext/>" : "",
    options.numId ? `<w:numPr><w:ilvl w:val="0"/><w:numId w:val="${options.numId}"/></w:numPr>` : "",
    options.bar ? `<w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="C7CDD6"/></w:pBdr>` : "",
    options.rule ? `<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="D0D5DD"/></w:pBdr>` : "",
    options.shade ? `<w:shd w:val="clear" w:color="auto" w:fill="${options.shade}"/>` : "",
    spacing,
    options.left || options.hanging
      ? `<w:ind w:left="${options.left ?? 0}"${options.hanging ? ` w:hanging="${options.hanging}"` : ""}/>`
      : "",
  ].join("");
  return `<w:p>${props ? `<w:pPr>${props}</w:pPr>` : ""}${runs.map((run) => runXml(run, options)).join("")}</w:p>`;
}

const plain = (text: string): Run[] => [{ text }];

function tableXml(header: Run[][], rows: Run[][][]): string {
  const columns = Math.max(header.length, ...rows.map((row) => row.length), 1);
  const total = 9360; // the text width of a Letter page with one-inch margins, in twips
  const each = Math.floor(total / columns);
  const border = (side: string) => `<w:${side} w:val="single" w:sz="4" w:space="0" w:color="D0D5DD"/>`;

  const cell = (runs: Run[], head: boolean) =>
    `<w:tc><w:tcPr><w:tcW w:w="${each}" w:type="dxa"/>${
      head ? `<w:shd w:val="clear" w:color="auto" w:fill="F2F4F7"/>` : ""
    }</w:tcPr>${para(head ? runs.map((run) => ({ ...run, bold: true })) : runs, { before: 40, after: 40 })}</w:tc>`;

  const row = (cells: Run[][], head: boolean) =>
    `<w:tr>${head ? "<w:trPr><w:tblHeader/></w:trPr>" : ""}${
      Array.from({ length: columns }, (_, i) => cell(cells[i] ?? [], head)).join("")
    }</w:tr>`;

  return `<w:tbl><w:tblPr><w:tblW w:w="${total}" w:type="dxa"/><w:tblBorders>${
    ["top", "left", "bottom", "right", "insideH", "insideV"].map(border).join("")
  }</w:tblBorders><w:tblLayout w:type="fixed"/><w:tblCellMar><w:left w:w="100" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr><w:tblGrid>${
    Array.from({ length: columns }, () => `<w:gridCol w:w="${each}"/>`).join("")
  }</w:tblGrid>${row(header, true)}${rows.map((cells) => row(cells, false)).join("")}</w:tbl>${
    // Word wants a paragraph after a table, and the gap is nicer for it.
    para([], { after: 120 })
  }`;
}

interface NumberingState {
  /** The next list number to hand out. 1 is the bullets, 2 the numbered base. */
  next: number;
  /** One `w:num` for each numbered list, so each starts where it says. */
  nums: string[];
}

function blocksXml(blocks: Block[], state: NumberingState): string {
  return blocks.map((block) => {
    switch (block.type) {
      case "heading":
        // The document title is the Title and a section is Heading 1, so a
        // heading inside the text starts at Heading 2.
        return para(block.runs, { style: block.level <= 2 ? "Heading2" : "Heading3", keepNext: true });
      case "paragraph":
        return para(block.runs);
      case "bullets":
        return block.items.map((runs, at) => para(runs, { numId: 1, after: at === block.items.length - 1 ? 120 : 40 }))
          .join("");
      case "numbered": {
        const id = state.next++;
        state.nums.push(
          `<w:num w:numId="${id}"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="${block.start}"/></w:lvlOverride></w:num>`,
        );
        return block.items.map((runs, at) => para(runs, { numId: id, after: at === block.items.length - 1 ? 120 : 40 }))
          .join("");
      }
      case "quote":
        return para(block.runs, { bar: true, left: 360, color: "475467", after: 120 });
      case "code":
        return block.text.split("\n").map((line) =>
          para([{ text: line || " ", code: true }], { shade: "F1F3F5", after: 0, size: 20 })
        ).join("") + para([], { after: 120 });
      case "rule":
        return para([], { rule: true, after: 160 });
      case "table":
        return tableXml(block.header, block.rows);
    }
  }).join("");
}

export function buildDocx(doc: Document): Uint8Array {
  const state: NumberingState = { next: 3, nums: [] };

  const body = [
    para(plain(doc.title), { style: "Title" }),
    doc.subtitle ? para(plain(doc.subtitle), { style: "Subtitle" }) : "",
    ...doc.sections.flatMap((section) => [
      section.heading ? para(plain(section.heading), { style: "Heading1", keepNext: true }) : "",
      ...section.paragraphs.map((text) => blocksXml(parseBlocks(text), state)),
    ]),
  ].join("");

  const ns = `xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ` +
    `xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"`;

  const documentXml = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<w:document ${ns}><w:body>${body}<w:sectPr>` +
    `<w:footerReference w:type="default" r:id="rId3"/>` +
    `<w:pgSz w:w="12240" w:h="15840"/>` +
    `<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>` +
    `</w:sectPr></w:body></w:document>`;

  const heading = (id: string, name: string, size: number, before: number, after: number, outline: number) =>
    `<w:style w:type="paragraph" w:styleId="${id}"><w:name w:val="${name}"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>` +
    `<w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="${before}" w:after="${after}"/><w:outlineLvl w:val="${outline}"/></w:pPr>` +
    `<w:rPr><w:b/><w:color w:val="101828"/><w:sz w:val="${size}"/></w:rPr></w:style>`;

  // Real heading styles, so the document has an outline and not just bold text.
  const stylesXml = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` +
    `<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:color w:val="1D2939"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>` +
    `<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="288" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>` +
    `<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>` +
    `<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>` +
    `<w:pPr><w:spacing w:after="80"/></w:pPr><w:rPr><w:b/><w:color w:val="101828"/><w:sz w:val="52"/></w:rPr></w:style>` +
    `<w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>` +
    `<w:pPr><w:spacing w:after="360"/></w:pPr><w:rPr><w:color w:val="667085"/><w:sz w:val="26"/></w:rPr></w:style>` +
    heading("Heading1", "heading 1", 32, 400, 140, 0) +
    heading("Heading2", "heading 2", 26, 280, 100, 1) +
    heading("Heading3", "heading 3", 23, 200, 80, 2) +
    `</w:styles>`;

  // Bullets are list 1; the numbered base is list 2, and each numbered list in
  // the text gets its own number from 3 so it starts where it should.
  const numberingXml = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` +
    `<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>` +
    `<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/>` +
    `<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>` +
    `<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>` +
    `<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/>` +
    `<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>` +
    `<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>` +
    `<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>` +
    state.nums.join("") +
    `</w:numbering>`;

  const footerXml = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:jc w:val="center"/></w:pPr>` +
    `<w:r><w:rPr><w:color w:val="98A2B3"/><w:sz w:val="18"/></w:rPr><w:t xml:space="preserve">Postpilot · Page </w:t></w:r>` +
    `<w:r><w:rPr><w:color w:val="98A2B3"/><w:sz w:val="18"/></w:rPr><w:fldChar w:fldCharType="begin"/></w:r>` +
    `<w:r><w:rPr><w:color w:val="98A2B3"/><w:sz w:val="18"/></w:rPr><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>` +
    `<w:r><w:rPr><w:color w:val="98A2B3"/><w:sz w:val="18"/></w:rPr><w:fldChar w:fldCharType="separate"/></w:r>` +
    `<w:r><w:rPr><w:color w:val="98A2B3"/><w:sz w:val="18"/></w:rPr><w:t>1</w:t></w:r>` +
    `<w:r><w:rPr><w:color w:val="98A2B3"/><w:sz w:val="18"/></w:rPr><w:fldChar w:fldCharType="end"/></w:r>` +
    `</w:p></w:ftr>`;

  const rels = (id: string, type: string, target: string) =>
    `<Relationship Id="${id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/${type}" Target="${target}"/>`;

  return zipSync({
    "[Content_Types].xml": strToU8(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
        `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
        `<Default Extension="xml" ContentType="application/xml"/>` +
        `<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>` +
        `<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>` +
        `<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>` +
        `<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>` +
        `</Types>`,
    ),
    "_rels/.rels": strToU8(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
        rels("rId1", "officeDocument", "word/document.xml") +
        `</Relationships>`,
    ),
    "word/_rels/document.xml.rels": strToU8(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
        rels("rId1", "styles", "styles.xml") +
        rels("rId2", "numbering", "numbering.xml") +
        rels("rId3", "footer", "footer1.xml") +
        `</Relationships>`,
    ),
    "word/document.xml": strToU8(documentXml),
    "word/styles.xml": strToU8(stylesXml),
    "word/numbering.xml": strToU8(numberingXml),
    "word/footer1.xml": strToU8(footerXml),
  });
}

// ---------------------------------------------------------------------- PDF

/** The standard fonts cover WinAnsi only. Anything outside it -- emoji, a
 *  symbol -- would throw at draw time and lose the whole document, so it is
 *  mapped to the nearest plain character first or dropped. */
function ansi(text: string): string {
  return text
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[–—]/g, "-")
    .replace(/…/g, "...")
    .replace(/[•·]/g, "-")
    .replace(/[^\x20-\x7E -ÿ\n]/g, "");
}

interface Piece {
  text: string;
  font: PDFFont;
  x: number;
}

export async function buildPdf(doc: Document): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  pdf.setTitle(ansi(doc.title));
  pdf.setProducer("Postpilot");

  const fonts = {
    regular: await pdf.embedFont(StandardFonts.Helvetica),
    bold: await pdf.embedFont(StandardFonts.HelveticaBold),
    italic: await pdf.embedFont(StandardFonts.HelveticaOblique),
    boldItalic: await pdf.embedFont(StandardFonts.HelveticaBoldOblique),
    mono: await pdf.embedFont(StandardFonts.Courier),
  };
  const fontFor = (run: Run, forceBold: boolean): PDFFont => {
    if (run.code) return fonts.mono;
    const bold = run.bold || forceBold;
    return bold && run.italic ? fonts.boldItalic : bold ? fonts.bold : run.italic ? fonts.italic : fonts.regular;
  };

  const pageWidth = 612;
  const pageHeight = 792;
  const margin = 64;
  const usable = pageWidth - margin * 2;
  const ink = rgb(0.11, 0.16, 0.22);
  const quiet = rgb(0.4, 0.44, 0.52);
  const line = rgb(0.82, 0.84, 0.87);
  const shade = rgb(0.95, 0.96, 0.97);

  let page: PDFPage = pdf.addPage([pageWidth, pageHeight]);
  let y = pageHeight - margin;

  const room = (needed: number) => {
    // A new page when the next line would cross the bottom margin, so nothing
    // is ever drawn off the page.
    if (y - needed < margin) {
      page = pdf.addPage([pageWidth, pageHeight]);
      y = pageHeight - margin;
    }
  };

  /** Width as it is DRAWN. pdf-lib's own measure applies kerning pairs, and a
   *  viewer does not when it shows the text, so a word like "Teach" was placed
   *  narrower than it is and the space after it closed up. One character at a
   *  time has no pairs to kern. */
  const measure = (font: PDFFont, text: string, size: number): number =>
    Array.from(text).reduce((total, character) => total + font.widthOfTextAtSize(character, size), 0);

  /** Runs, broken into lines that fit `width`, each piece placed by measuring
   *  rather than counting characters. Bold and italic stay inside the line. */
  const layout = (runs: Run[], size: number, width: number, forceBold = false): Piece[][] => {
    const lines: Piece[][] = [];
    let current: Piece[] = [];
    let used = 0;

    for (const run of runs) {
      const font = fontFor(run, forceBold);
      for (const token of ansi(run.text).split(/(\s+)/)) {
        if (!token) continue;
        const blank = /^\s+$/.test(token);
        const text = blank ? " " : token;
        const measured = measure(font, text, size);
        if (!blank && used + measured > width && current.length > 0) {
          // The line ends before this word; its trailing space goes with it.
          while (current.length > 0 && current[current.length - 1].text === " ") current.pop();
          lines.push(current);
          current = [];
          used = 0;
        }
        if (blank && current.length === 0) continue;
        current.push({ text, font, x: used });
        used += measured;
      }
    }
    while (current.length > 0 && current[current.length - 1].text === " ") current.pop();
    if (current.length > 0) lines.push(current);
    return lines.length > 0 ? lines : [[]];
  };

  const draw = (lines: Piece[][], x: number, size: number, color = ink, leading = 1.4) => {
    for (const row of lines) {
      room(size * leading);
      for (const piece of row) {
        page.drawText(piece.text, { x: x + piece.x, y: y - size, size, font: piece.font, color });
      }
      y -= size * leading;
    }
  };

  const text = (runs: Run[], size: number, options: { x?: number; width?: number; bold?: boolean; color?: ReturnType<typeof rgb>; gap?: number } = {}) => {
    const x = options.x ?? margin;
    draw(layout(runs, size, options.width ?? usable - (x - margin), options.bold), x, size, options.color);
    y -= options.gap ?? 0;
  };

  // The title block.
  text(plain(doc.title), 24, { bold: true, gap: 4 });
  if (doc.subtitle) text(plain(doc.subtitle), 12, { color: quiet, gap: 16 });

  const blocks = (list: Block[]) => {
    for (const block of list) {
      switch (block.type) {
        case "heading": {
          const size = block.level <= 2 ? 14 : 12;
          y -= 6;
          room(size * 2.4);
          text(block.runs, size, { bold: true, gap: 3 });
          break;
        }
        case "paragraph":
          text(block.runs, 11, { gap: 8 });
          break;
        case "bullets":
          block.items.forEach((runs, at) => {
            room(11 * 1.4);
            page.drawCircle({ x: margin + 7, y: y - 8, size: 1.9, color: ink });
            text(runs, 11, { x: margin + 22, gap: at === block.items.length - 1 ? 8 : 3 });
          });
          break;
        case "numbered":
          block.items.forEach((runs, at) => {
            room(11 * 1.4);
            const label = `${block.start + at}.`;
            page.drawText(label, { x: margin + 2, y: y - 11, size: 11, font: fonts.bold, color: ink });
            text(runs, 11, { x: margin + 24, gap: at === block.items.length - 1 ? 8 : 3 });
          });
          break;
        case "quote": {
          const top = y;
          text(block.runs, 11, { x: margin + 16, color: quiet, gap: 0 });
          page.drawRectangle({ x: margin + 3, y: y + 2, width: 2.5, height: Math.max(top - y - 2, 6), color: line });
          y -= 8;
          break;
        }
        case "code":
          for (const row of block.text.split("\n")) {
            room(12);
            page.drawRectangle({ x: margin, y: y - 12, width: usable, height: 13, color: shade });
            page.drawText(ansi(row), { x: margin + 6, y: y - 9, size: 9, font: fonts.mono, color: ink });
            y -= 13;
          }
          y -= 8;
          break;
        case "rule":
          room(14);
          page.drawLine({ start: { x: margin, y: y - 6 }, end: { x: margin + usable, y: y - 6 }, thickness: 0.7, color: line });
          y -= 16;
          break;
        case "table": {
          const columns = Math.max(block.header.length, ...block.rows.map((row) => row.length), 1);
          const widthOf = usable / columns;
          const pad = 5;
          const size = 10;
          const row = (cells: Run[][], head: boolean) => {
            const wrapped = Array.from({ length: columns }, (_, i) => layout(cells[i] ?? [], size, widthOf - pad * 2, head));
            const height = Math.max(...wrapped.map((lines) => lines.length)) * size * 1.35 + pad * 2;
            room(height);
            if (head) page.drawRectangle({ x: margin, y: y - height, width: usable, height, color: shade });
            wrapped.forEach((lines, i) => {
              let cursor = y - pad;
              for (const rowLine of lines) {
                for (const piece of rowLine) {
                  page.drawText(piece.text, { x: margin + i * widthOf + pad + piece.x, y: cursor - size, size, font: piece.font, color: ink });
                }
                cursor -= size * 1.35;
              }
            });
            page.drawLine({ start: { x: margin, y: y - height }, end: { x: margin + usable, y: y - height }, thickness: 0.6, color: line });
            y -= height;
          };
          room(40);
          page.drawLine({ start: { x: margin, y }, end: { x: margin + usable, y }, thickness: 0.6, color: line });
          row(block.header, true);
          for (const cells of block.rows) row(cells, false);
          y -= 12;
          break;
        }
      }
    }
  };

  for (const section of doc.sections) {
    if (section.heading) {
      y -= 8;
      room(16 * 2.4);
      text(plain(section.heading), 16, { bold: true, gap: 4 });
    }
    for (const paragraph of section.paragraphs) blocks(parseBlocks(paragraph));
  }

  // Page numbers, once the pages are known.
  const pages = pdf.getPages();
  pages.forEach((each, index) => {
    const label = `Postpilot  -  ${index + 1} / ${pages.length}`;
    const width = measure(fonts.regular, label, 8);
    each.drawText(label, { x: (pageWidth - width) / 2, y: 30, size: 8, font: fonts.regular, color: quiet });
  });

  return await pdf.save();
}

// ---------------------------------------------------------------------- ZIP

export interface PackageFile {
  path: string;
  bytes: Uint8Array;
}

/** A package with a manifest listing what is inside and how big each part is,
 *  so the card can show the contents before anybody opens it. */
export function buildZip(
  name: string,
  files: PackageFile[],
  /** `store` packs without compressing. Pictures, video and audio are already
   *  compressed, and squeezing them again costs the CPU an edge function has
   *  least of for bytes it will not save. */
  options: { store?: boolean } = {},
): {
  bytes: Uint8Array;
  manifest: Array<{ path: string; size: number }>;
} {
  const manifest = files.map((f) => ({ path: f.path, size: f.bytes.byteLength }));
  const entries: Record<string, Uint8Array | [Uint8Array, { level: 0 }]> = {};
  for (const file of files) {
    entries[file.path] = options.store ? [file.bytes, { level: 0 }] : file.bytes;
  }
  entries["MANIFEST.txt"] = strToU8(
    `${name}\n\n` + manifest.map((m) => `${m.path}  (${m.size} bytes)`).join("\n") + "\n",
  );
  return { bytes: zipSync(entries), manifest };
}
