import SwiftUI
import UIKit

// An answer drawn the way ChatGPT draws one: headings, bold, bullets, numbered
// steps, a table, spacing and emoji -- instead of the symbols they are written
// in (Abel, 2 Nov 2026, with ChatGPT's answer beside ours: "the way it uses the
// punctuation, the emojis, the spaces ... looks so good").
//
// Written by hand rather than taken from a package: the answer streams in a few
// characters at a time, so half a table and an unclosed `**` have to draw as
// something sensible, and the text has to stay one selectable run so a sentence
// can still be picked out of it (Abel, 17 Sep 2026).

/// One block of an answer.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    /// `start` because a model often writes "1." and "2." with a blank line
    /// between them, which makes each its own list; the numbers must go on.
    case numbered(start: Int, items: [String])
    case quote(String)
    case code(String)
    case rule
    case table(header: [String], rows: [[String]])
}

/// What is drawn as one piece: text (selectable as a whole), a table, or a rule.
enum MarkdownSegment: Equatable {
    case text([MarkdownBlock])
    case table(header: [String], rows: [[String]])
    case rule
}

enum ChatMarkdown {

    // MARK: - Blocks

    static func blocks(_ source: String) -> [MarkdownBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var numberedStart = 1
        var quote: [String] = []
        var code: [String]?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullets(bullets))
            bullets = []
        }
        func flushNumbered() {
            guard !numbered.isEmpty else { return }
            blocks.append(.numbered(start: numberedStart, items: numbered))
            numbered = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }
        func flushAll() {
            flushParagraph()
            flushBullets()
            flushNumbered()
            flushQuote()
        }

        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Inside a fenced block everything is code until the closing fence.
            if code != nil {
                if line.hasPrefix("```") {
                    blocks.append(.code((code ?? []).joined(separator: "\n")))
                    code = nil
                } else {
                    code?.append(raw)
                }
                index += 1
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                code = []
                index += 1
                continue
            }

            if line.isEmpty {
                flushAll()
                index += 1
                continue
            }

            // A table is a line of cells followed by a separator row. Until the
            // separator has arrived it is only a line with pipes in it.
            if line.contains("|"), index + 1 < lines.count, isSeparator(lines[index + 1]) {
                flushAll()
                let header = cells(line)
                var rows: [[String]] = []
                var next = index + 2
                while next < lines.count {
                    let candidate = lines[next].trimmingCharacters(in: .whitespaces)
                    if candidate.isEmpty || !candidate.contains("|") { break }
                    rows.append(cells(candidate))
                    next += 1
                }
                blocks.append(.table(header: header, rows: rows))
                index = next
                continue
            }

            if let heading = headingOf(line) {
                flushAll()
                blocks.append(heading)
                index += 1
                continue
            }

            if isRule(line) {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                flushBullets()
                flushNumbered()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }

            if let item = bulletItem(line) {
                flushParagraph()
                flushNumbered()
                flushQuote()
                bullets.append(item)
                index += 1
                continue
            }

            if let (number, item) = numberedItem(line) {
                flushParagraph()
                flushBullets()
                flushQuote()
                if numbered.isEmpty { numberedStart = number }
                numbered.append(item)
                index += 1
                continue
            }

            // An indented line under a list item goes on that item.
            let indented = raw.hasPrefix(" ") || raw.hasPrefix("\t")
            if indented, !bullets.isEmpty {
                bullets[bullets.count - 1] += " " + line
                index += 1
                continue
            }
            if indented, !numbered.isEmpty {
                numbered[numbered.count - 1] += " " + line
                index += 1
                continue
            }

            flushBullets()
            flushNumbered()
            flushQuote()
            paragraph.append(line)
            index += 1
        }

        // Written so far: a fence still open is shown as the code it is.
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }

    static func segments(_ blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var run: [MarkdownBlock] = []

        func flush() {
            guard !run.isEmpty else { return }
            segments.append(.text(run))
            run = []
        }

        for block in blocks {
            switch block {
            case .table(let header, let rows):
                flush()
                segments.append(.table(header: header, rows: rows))
            case .rule:
                flush()
                segments.append(.rule)
            default:
                run.append(block)
            }
        }
        flush()
        return segments
    }

    private static func headingOf(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes.count, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparator(_ line: String) -> Bool {
        let row = cells(line)
        guard !row.isEmpty, line.contains("-") else { return false }
        return row.allSatisfy { cell in
            let bare = cell.replacingOccurrences(of: ":", with: "")
            return !bare.isEmpty && bare.allSatisfy { $0 == "-" }
        }
    }

    // MARK: - Inline: **bold**, *italic*, `code`, [links](https://...)

    /// One line of text with its markers turned into styling. A marker that is
    /// never closed is bold to the end (what a half-streamed answer should look
    /// like) or, for a lone `*`, just a character: "5 * 3" stays "5 * 3".
    static func inline(_ text: String, font: UIFont, color: UIColor, dark: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let characters = Array(text)
        var buffer = ""
        var bold = false
        var italic = false

        func attributes(code: Bool = false) -> [NSAttributedString.Key: Any] {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }
            var face = font
            if code {
                face = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: bold ? .semibold : .regular)
            } else if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                face = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            var found: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: color]
            if code { found[.backgroundColor] = UIColor.secondarySystemFill }
            return found
        }

        func flush(code: Bool = false) {
            guard !buffer.isEmpty else { return }
            result.append(NSAttributedString(string: buffer, attributes: attributes(code: code)))
            buffer = ""
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]

            // `code`
            if character == "`", let end = characters[(index + 1)...].firstIndex(of: "`") {
                flush()
                buffer = String(characters[(index + 1)..<end])
                flush(code: true)
                index = end + 1
                continue
            }

            // **bold**
            if character == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                flush()
                bold.toggle()
                index += 2
                continue
            }

            // *italic*, only when it is plainly one: opened against a word and closed later.
            if character == "*" {
                let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
                let previous: Character? = index > 0 ? characters[index - 1] : nil
                if italic {
                    if let previous, !previous.isWhitespace {
                        flush()
                        italic = false
                        index += 1
                        continue
                    }
                } else if let next, !next.isWhitespace, characters[(index + 1)...].contains("*") {
                    flush()
                    italic = true
                    index += 1
                    continue
                }
                buffer.append(character)
                index += 1
                continue
            }

            // [label](url)
            if character == "[",
               let close = characters[(index + 1)...].firstIndex(of: "]"),
               close + 1 < characters.count, characters[close + 1] == "(",
               let paren = characters[(close + 2)...].firstIndex(of: ")") {
                flush()
                let label = String(characters[(index + 1)..<close])
                let target = String(characters[(close + 2)..<paren])
                // A web answer's source: drawn as ChatGPT's grey chip, opening
                // the page it names.
                if target.hasPrefix("cite:") {
                    let chip = NSMutableAttributedString(attachment: sourceChip(label, font: font, dark: dark))
                    if let url = URL(string: String(target.dropFirst(5))) {
                        chip.addAttribute(.link, value: url, range: NSRange(location: 0, length: chip.length))
                    }
                    result.append(chip)
                    index = paren + 1
                    continue
                }
                var linked = attributes()
                if let url = URL(string: target) { linked[.link] = url }
                result.append(NSAttributedString(string: label, attributes: linked))
                index = paren + 1
                continue
            }

            buffer.append(character)
            index += 1
        }
        flush()
        return result
    }

    /// How much of `text` the typewriter may show when it wants `wanted`
    /// characters, without stopping inside a link: a cut inside "[label](url)"
    /// moves to the link's end, or -- while its end has not arrived -- back to
    /// its start. Half a link is raw markdown on screen, and half a source chip
    /// is "[livescore.com +1](cite:htt".
    static func revealCut(_ text: String, wanted: Int) -> Int {
        let characters = Array(text)
        // All of what is waiting can still end inside a link.
        let wanted = min(wanted, characters.count)
        guard let open = characters[..<wanted].lastIndex(of: "[") else { return wanted }
        var at = open + 1
        while at < characters.count, characters[at] != "]", characters[at] != "\n" { at += 1 }
        guard at < characters.count else { return open }          // the label is still coming
        guard characters[at] == "]" else { return wanted }        // a bracket, not a link
        guard at + 1 < characters.count else { return open }      // its "(" may still come
        guard characters[at + 1] == "(" else { return wanted }    // "[x] then words": not a link
        at += 2
        while at < characters.count, characters[at] != ")", !characters[at].isWhitespace { at += 1 }
        guard at < characters.count else { return open }          // the address is still coming
        guard characters[at] == ")" else { return wanted }
        return max(wanted, at + 1)
    }

    /// Chips already drawn, so redrawing the same answer hands the text view the
    /// same attachment and it leaves the text alone. Keyed by label, size and
    /// light or dark.
    nonisolated(unsafe) private static var chips: [String: NSTextAttachment] = [:]

    /// ChatGPT's source chip: the site's name ("livescore.com +1") in a small
    /// grey capsule, sitting in the line like a word (Abel, 3 Nov 2026: "add the
    /// ChatGPT small source chips").
    static func sourceChip(_ label: String, font: UIFont, dark: Bool) -> NSTextAttachment {
        let key = "\(label)|\(font.pointSize)|\(dark)"
        if let drawn = chips[key] { return drawn }

        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let face = UIFont.systemFont(ofSize: (font.pointSize * 0.72).rounded(), weight: .medium)
        let words = NSAttributedString(string: label, attributes: [
            .font: face,
            .foregroundColor: UIColor.secondaryLabel.resolvedColor(with: traits),
        ])
        let measured = words.size()
        let size = CGSize(width: ceil(measured.width) + 16, height: ceil(face.lineHeight) + 6)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.tertiarySystemFill.resolvedColor(with: traits).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2).fill()
            words.draw(at: CGPoint(x: 8, y: (size.height - measured.height) / 2))
        }
        let attachment = NSTextAttachment(image: image)
        // Centred on the letters around it, not sitting on their baseline.
        attachment.bounds = CGRect(
            x: 0, y: (font.capHeight - size.height) / 2,
            width: size.width, height: size.height
        )
        chips[key] = attachment
        return attachment
    }

    /// Inline markdown for a SwiftUI `Text` -- a table cell.
    static func attributedString(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: - Text blocks as one attributed run

    /// Everything that is text -- headings, paragraphs, lists, quotes, code --
    /// as ONE attributed string, so it is one selectable run.
    static func attributed(_ blocks: [MarkdownBlock], base: UIFont, color: UIColor, dark: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()

        func paragraphStyle(
            spacing: CGFloat,
            before: CGFloat = 0,
            indent: CGFloat = 0,
            hanging: CGFloat = 0
        ) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = spacing
            style.paragraphSpacingBefore = before
            style.firstLineHeadIndent = indent
            style.headIndent = indent + hanging
            if hanging > 0 {
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)]
            }
            return style
        }

        func add(_ content: NSAttributedString, style: NSParagraphStyle, last: Bool) {
            let text = NSMutableAttributedString(attributedString: content)
            if !last { text.append(NSAttributedString(string: "\n", attributes: [.font: base])) }
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            out.append(text)
        }

        for (position, block) in blocks.enumerated() {
            let isLast = position == blocks.count - 1
            switch block {
            case .heading(let level, let text):
                let extra: CGFloat = level == 1 ? 5 : level == 2 ? 3 : 1
                let font = UIFont.systemFont(ofSize: base.pointSize + extra, weight: .bold)
                add(
                    inline(text, font: font, color: color, dark: dark),
                    style: paragraphStyle(spacing: 6, before: position == 0 ? 0 : 8),
                    last: isLast
                )

            case .paragraph(let text):
                add(inline(text, font: base, color: color, dark: dark), style: paragraphStyle(spacing: 10), last: isLast)

            case .bullets(let items):
                for (at, item) in items.enumerated() {
                    let line = NSMutableAttributedString(
                        string: "•\t",
                        attributes: [.font: base, .foregroundColor: color]
                    )
                    line.append(inline(item, font: base, color: color, dark: dark))
                    let lastItem = at == items.count - 1
                    add(
                        line,
                        style: paragraphStyle(spacing: lastItem ? 10 : 4, indent: 4, hanging: 18),
                        last: isLast && lastItem
                    )
                }

            case .numbered(let start, let items):
                for (at, item) in items.enumerated() {
                    let line = NSMutableAttributedString(
                        string: "\(start + at).\t",
                        attributes: [.font: base, .foregroundColor: color]
                    )
                    line.append(inline(item, font: base, color: color, dark: dark))
                    let lastItem = at == items.count - 1
                    add(
                        line,
                        style: paragraphStyle(spacing: lastItem ? 10 : 4, indent: 0, hanging: 26),
                        last: isLast && lastItem
                    )
                }

            case .quote(let text):
                add(
                    inline(text, font: base, color: UIColor.secondaryLabel, dark: dark),
                    style: paragraphStyle(spacing: 10, indent: 12),
                    last: isLast
                )

            case .code(let text):
                let font = UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.9, weight: .regular)
                let content = NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .backgroundColor: UIColor.secondarySystemFill,
                ])
                add(content, style: paragraphStyle(spacing: 10, indent: 6), last: isLast)

            case .rule, .table:
                break
            }
        }
        return out
    }
}

// MARK: - The view

/// An assistant answer. Text runs are one selectable run each; a table is drawn
/// as a table; a rule as a line.
struct MarkdownText: View {
    let text: String

    /// Source chips are pictures, drawn for light or dark.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let segments = ChatMarkdown.segments(ChatMarkdown.blocks(text))
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let blocks):
                    SelectableText(
                        attributed: ChatMarkdown.attributed(
                            blocks,
                            base: UIFont.preferredFont(forTextStyle: .body),
                            color: UIColor.label,
                            dark: colorScheme == .dark
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .table(let header, let rows):
                    MarkdownTable(header: header, rows: rows)
                case .rule:
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A table the way ChatGPT draws one: a bold header, thin lines between rows,
/// cells that wrap.
private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 0) {
            line(header, bold: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                line(cells, bold: false)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func line(_ cells: [String], bold: Bool) -> some View {
        Divider().gridCellUnsizedAxes(.horizontal)
        GridRow {
            ForEach(0..<columns, id: \.self) { column in
                Text(ChatMarkdown.attributedString(column < cells.count ? cells[column] : ""))
                    .font(bold ? .subheadline.weight(.semibold) : .subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
            }
        }
    }
}
