import XCTest
@testable import ContentApp

final class TranscriptTests: XCTestCase {
    func testTypedWordsAndTranscriptComeBackApart() {
        let text = Transcript.compose(typed: "make this a hook", transcripts: ["hello and welcome"])
        let parts = Transcript.split(text)
        XCTAssertEqual(parts.typed, "make this a hook")
        XCTAssertEqual(parts.transcript, "hello and welcome")
    }

    func testAVideoSentOnItsOwnHasNoTypedWords() {
        let text = Transcript.compose(typed: "", transcripts: ["just the video"])
        let parts = Transcript.split(text)
        XCTAssertEqual(parts.typed, "")
        XCTAssertEqual(parts.transcript, "just the video")
    }

    func testSeveralVideosAreNumbered() {
        let text = Transcript.compose(typed: "compare", transcripts: ["first", "second"])
        let parts = Transcript.split(text)
        XCTAssertEqual(parts.transcript, "Video 1: first\n\nVideo 2: second")
    }

    func testAPlainMessageHasNoTranscript() {
        let parts = Transcript.split("just a question")
        XCTAssertEqual(parts.typed, "just a question")
        XCTAssertNil(parts.transcript)
    }
}
