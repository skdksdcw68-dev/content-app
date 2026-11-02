import XCTest
@testable import ContentApp

/// An answer is written in markdown and drawn as headings, bold, lists and a
/// table. These pin the reading of it -- including the half-written forms a
/// streaming answer passes through.
final class MarkdownTests: XCTestCase {

    func testHeadingBulletsAndNumberedSteps() {
        let blocks = ChatMarkdown.blocks("## Why\n\n- one\n- two\n\n1. first\n2. second")
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Why"),
            .bullets(["one", "two"]),
            .numbered(start: 1, items: ["first", "second"]),
        ])
    }

    /// ChatGPT-style steps often have a blank line between them; each is then
    /// its own list, and the numbers must carry on.
    func testNumberedStepsSeparatedByBlankLinesKeepTheirNumbers() {
        let blocks = ChatMarkdown.blocks("1. a\n\n2. b\n\n3. c")
        XCTAssertEqual(blocks, [
            .numbered(start: 1, items: ["a"]),
            .numbered(start: 2, items: ["b"]),
            .numbered(start: 3, items: ["c"]),
        ])
    }

    func testAListRightAfterALineOfTextNeedsNoBlankLine() {
        let blocks = ChatMarkdown.blocks("Video ideas:\n- one\n- two")
        XCTAssertEqual(blocks, [.paragraph("Video ideas:"), .bullets(["one", "two"])])
    }

    func testTable() {
        let source = "| Element | Strategy |\n|---|---|\n| Platform | YouTube |\n| Audience | International |"
        XCTAssertEqual(ChatMarkdown.blocks(source), [
            .table(header: ["Element", "Strategy"], rows: [["Platform", "YouTube"], ["Audience", "International"]]),
        ])
    }

    /// Until the separator row arrives it is a line with pipes, not a table.
    func testAHalfStreamedTableIsAParagraph() {
        XCTAssertEqual(ChatMarkdown.blocks("| a | b |"), [.paragraph("| a | b |")])
    }

    func testQuoteRuleAndCode() {
        let blocks = ChatMarkdown.blocks("> careful\n\n---\n\n```\nlet x = 1\n```")
        XCTAssertEqual(blocks, [.quote("careful"), .rule, .code("let x = 1")])
    }

    func testAnOpenCodeFenceIsShownAsCodeSoFar() {
        XCTAssertEqual(ChatMarkdown.blocks("```\nlet x"), [.code("let x")])
    }

    func testTablesAndRulesSplitTheTextIntoSegments() {
        let blocks = ChatMarkdown.blocks("Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter")
        let segments = ChatMarkdown.segments(blocks)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .text([.paragraph("Intro")]))
        XCTAssertEqual(segments[1], .table(header: ["a", "b"], rows: [["1", "2"]]))
        XCTAssertEqual(segments[2], .text([.paragraph("After")]))
    }

    // MARK: - Inline

    func testBoldItalicAndCodeLoseTheirMarkers() {
        let text = ChatMarkdown.inline("a **bold** and *soft* and `code`", font: .systemFont(ofSize: 17), color: .label)
        XCTAssertEqual(text.string, "a bold and soft and code")
    }

    func testBoldIsBold() {
        let text = ChatMarkdown.inline("a **bold** b", font: .systemFont(ofSize: 17), color: .label)
        var isBold = false
        text.enumerateAttribute(.font, in: NSRange(location: 2, length: 4)) { value, _, _ in
            isBold = (value as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
        }
        XCTAssertTrue(isBold)
    }

    /// A lone star is a character, not the start of italics: "5 * 3" stays itself.
    func testALoneStarIsJustAStar() {
        let text = ChatMarkdown.inline("5 * 3 = 15", font: .systemFont(ofSize: 17), color: .label)
        XCTAssertEqual(text.string, "5 * 3 = 15")
    }

    /// Streaming: the closing markers have not arrived yet. The text must not
    /// be lost or show its stars.
    func testUnclosedBoldStillShowsItsWords() {
        let text = ChatMarkdown.inline("**Bold te", font: .systemFont(ofSize: 17), color: .label)
        XCTAssertEqual(text.string, "Bold te")
    }

    func testAnEmojiSurvives() {
        let text = ChatMarkdown.inline("Nice 🔥 work", font: .systemFont(ofSize: 17), color: .label)
        XCTAssertEqual(text.string, "Nice 🔥 work")
    }

    func testALinkKeepsItsLabel() {
        let text = ChatMarkdown.inline("see [the guide](https://example.com) now", font: .systemFont(ofSize: 17), color: .label)
        XCTAssertEqual(text.string, "see the guide now")
    }

    // MARK: - The whole answer

    func testAnAnswerBecomesOneRunWithBulletsAndNumbers() {
        let blocks = ChatMarkdown.blocks("**Short answer.**\n\n- one\n- two\n\n1. first")
        let text = ChatMarkdown.attributed(blocks, base: .systemFont(ofSize: 17), color: .label)
        XCTAssertTrue(text.string.contains("•\tone"))
        XCTAssertTrue(text.string.contains("•\ttwo"))
        XCTAssertTrue(text.string.contains("1.\tfirst"))
        XCTAssertFalse(text.string.contains("**"))
    }
}
