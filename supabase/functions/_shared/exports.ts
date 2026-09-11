/**
 * Real files from structured content: DOCX, PDF and ZIP.
 *
 * "Export it as a DOCX" is not satisfied by markdown with a .docx extension.
 * Word refuses it, Pages shows it as text, and the person concludes the export
 * is broken -- correctly. So each format is built properly:
 *
 *   DOCX  a zip of WordprocessingML parts. Five files are enough for Word,
 *         Pages and Google Docs to open it with real headings and paragraphs.
 *   PDF   laid out with pdf-lib, with line wrapping and page breaks, because a
 *         report that runs off the bottom of page one is not a report.
 *   ZIP   fflate, with a manifest, because a package somebody cannot see into
 *         before opening is a package they will not trust.
 *
 * All three take the same input -- a title and sections of paragraphs -- so the
 * agent produces one structure and the person picks the format.
 */

import { strToU8, zipSync } from "https://esm.sh/fflate@0.8.2";
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";

export interface Section {
  heading?: string;
  paragraphs: string[];
}

export interface Document {
  title: string;
  subtitle?: string;
  sections: Section[];
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

function para(text: string, style?: string): string {
  const props = style ? `<w:pPr><w:pStyle w:val="${style}"/></w:pPr>` : "";
  return `<w:p>${props}<w:r><w:t xml:space="preserve">${esc(text)}</w:t></w:r></w:p>`;
}

export function buildDocx(doc: Document): Uint8Array {
  const body = [
    para(doc.title, "Title"),
    doc.subtitle ? para(doc.subtitle, "Subtitle") : "",
    ...doc.sections.flatMap((section) => [
      section.heading ? para(section.heading, "Heading1") : "",
      ...section.paragraphs.map((p) => para(p)),
    ]),
  ].join("");

  const documentXml =
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` +
    `<w:body>${body}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>` +
    `<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>` +
    `</w:sectPr></w:body></w:document>`;

  // Real heading styles, so the document has an outline and not just bold text.
  const stylesXml =
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">` +
    `<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault>` +
    `<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>` +
    `<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>` +
    `<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>` +
    `<w:pPr><w:spacing w:after="120"/></w:pPr><w:rPr><w:b/><w:sz w:val="48"/></w:rPr></w:style>` +
    `<w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/>` +
    `<w:pPr><w:spacing w:after="360"/></w:pPr><w:rPr><w:color w:val="666666"/><w:sz w:val="26"/></w:rPr></w:style>` +
    `<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>` +
    `<w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr>` +
    `<w:rPr><w:b/><w:sz w:val="30"/></w:rPr></w:style>` +
    `</w:styles>`;

  return zipSync({
    "[Content_Types].xml": strToU8(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
        `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
        `<Default Extension="xml" ContentType="application/xml"/>` +
        `<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>` +
        `<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>` +
        `</Types>`,
    ),
    "_rels/.rels": strToU8(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
        `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>` +
        `</Relationships>`,
    ),
    "word/_rels/document.xml.rels": strToU8(
      `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
        `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>` +
        `</Relationships>`,
    ),
    "word/document.xml": strToU8(documentXml),
    "word/styles.xml": strToU8(stylesXml),
  });
}

// ---------------------------------------------------------------------- PDF

/** Splits text into lines that fit `width` at `size`, by measuring rather than
 *  counting characters -- a proportional font makes character counts lie. */
function wrap(text: string, width: number, measure: (s: string) => number): string[] {
  const lines: string[] = [];
  for (const block of text.split("\n")) {
    let line = "";
    for (const word of block.split(/\s+/).filter(Boolean)) {
      const next = line ? `${line} ${word}` : word;
      if (measure(next) > width && line) {
        lines.push(line);
        line = word;
      } else {
        line = next;
      }
    }
    lines.push(line);
  }
  return lines;
}

/** The standard fonts cover WinAnsi only. Anything outside it -- curly quotes,
 *  em dashes, emoji -- would throw at draw time and lose the whole document, so
 *  it is mapped to the nearest plain character first. */
function ansi(text: string): string {
  return text
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[–—]/g, "-")
    .replace(/…/g, "...")
    .replace(/•/g, "*")
    .replace(/[^\x20-\x7E -ÿ\n]/g, "");
}

export async function buildPdf(doc: Document): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  pdf.setTitle(ansi(doc.title));
  pdf.setProducer("Autocast");

  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);

  const pageWidth = 612;
  const pageHeight = 792;
  const margin = 64;
  const usable = pageWidth - margin * 2;

  let page = pdf.addPage([pageWidth, pageHeight]);
  let y = pageHeight - margin;

  const write = (text: string, font: typeof regular, size: number, gap: number, color = rgb(0.1, 0.1, 0.12)) => {
    const lines = wrap(ansi(text), usable, (s) => font.widthOfTextAtSize(s, size));
    for (const line of lines) {
      // A new page when the next line would cross the bottom margin, so nothing
      // is ever drawn off the page.
      if (y - size < margin) {
        page = pdf.addPage([pageWidth, pageHeight]);
        y = pageHeight - margin;
      }
      page.drawText(line, { x: margin, y: y - size, size, font, color });
      y -= size * 1.35;
    }
    y -= gap;
  };

  write(doc.title, bold, 22, 6);
  if (doc.subtitle) write(doc.subtitle, regular, 12, 14, rgb(0.4, 0.4, 0.45));
  for (const section of doc.sections) {
    if (section.heading) write(section.heading, bold, 14, 4);
    for (const p of section.paragraphs) write(p, regular, 11, 8);
  }

  return await pdf.save();
}

// ---------------------------------------------------------------------- ZIP

export interface PackageFile {
  path: string;
  bytes: Uint8Array;
}

/** A package with a manifest listing what is inside and how big each part is,
 *  so the card can show the contents before anybody opens it. */
export function buildZip(name: string, files: PackageFile[]): {
  bytes: Uint8Array;
  manifest: Array<{ path: string; size: number }>;
} {
  const manifest = files.map((f) => ({ path: f.path, size: f.bytes.byteLength }));
  const entries: Record<string, Uint8Array> = {};
  for (const file of files) entries[file.path] = file.bytes;
  entries["MANIFEST.txt"] = strToU8(
    `${name}\n\n` + manifest.map((m) => `${m.path}  (${m.size} bytes)`).join("\n") + "\n",
  );
  return { bytes: zipSync(entries), manifest };
}
