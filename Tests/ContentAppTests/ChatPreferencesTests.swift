import XCTest
@testable import ContentApp

/// Chat settings writes its taps as one first line of the saved instructions
/// and reads them back. These pin that round trip, and that words written
/// before this screen existed come back untouched.
final class ChatPreferencesTests: XCTestCase {

    func testDefaultsWriteNothingAndKeepTheOwnersWords() {
        XCTAssertEqual(ChatPreferences.compose(ChatPreferences(), own: " Call me Abel. "), "Call me Abel.")
        XCTAssertEqual(ChatPreferences.compose(ChatPreferences(), own: ""), "")
    }

    func testTapsAreWrittenAsAFirstLineAboveTheOwnWords() {
        let taps = ChatPreferences(length: .short, noHashtags: true, plainWords: false)
        XCTAssertEqual(
            ChatPreferences.compose(taps, own: "Call me Abel."),
            "Reply length: Short. No hashtags.\nCall me Abel."
        )
    }

    func testTapsWithoutWordsAreJustTheLine() {
        let taps = ChatPreferences(length: .detailed, noHashtags: false, plainWords: true)
        XCTAssertEqual(ChatPreferences.compose(taps, own: ""), "Reply length: Detailed. Plain words.")
    }

    func testWhatIsWrittenIsReadBack() {
        let taps = ChatPreferences(length: .detailed, noHashtags: true, plainWords: true)
        let saved = ChatPreferences.compose(taps, own: "I post scary stories.\nKeep it spooky.")
        let back = ChatPreferences.parse(saved)
        XCTAssertEqual(back.preferences, taps)
        XCTAssertEqual(back.own, "I post scary stories.\nKeep it spooky.")
    }

    func testOldInstructionsComeBackAsTheOwnWords() {
        let back = ChatPreferences.parse("Keep replies short. Call me Abel.")
        XCTAssertEqual(back.preferences, ChatPreferences())
        XCTAssertEqual(back.own, "Keep replies short. Call me Abel.")
    }
}
