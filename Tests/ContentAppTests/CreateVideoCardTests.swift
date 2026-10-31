import XCTest
@testable import ContentApp

/// What "Create photo video" sends, and what its card settles on. The server
/// (agent-chat, action "story") checks each of these fields; one spelled
/// differently here is a choice the person made that silently does nothing.
final class CreateVideoCardTests: XCTestCase {

    private func choice(voice: String = "storyteller", caption: String = "bold_pop", seconds: Int = 30) -> StoryChoice {
        StoryChoice(
            style: "scary",
            styleName: "Scary stories",
            topic: "a red lantern on an old bridge",
            seconds: seconds,
            look: CategoryLooks.looks(for: "scary").first,
            voice: SeriesVoice.all.first { $0.id == voice },
            caption: SeriesCaption.all.first { $0.id == caption }!
        )
    }

    func testThePayloadCarriesEveryChoiceTheServerReads() {
        let payload = choice().payload
        XCTAssertEqual(payload["type"] as? String, "story")
        XCTAssertEqual(payload["style"] as? String, "scary")
        XCTAssertEqual(payload["topic"] as? String, "a red lantern on an old bridge")
        XCTAssertEqual(payload["seconds"] as? Int, 30)
        XCTAssertEqual(payload["captionStyle"] as? String, "bold_pop")
        XCTAssertEqual(payload["voiceId"] as? String, SeriesVoice.all.first { $0.id == "storyteller" }?.elevenLabsID)
        XCTAssertEqual(payload["look"] as? String, CategoryLooks.looks(for: "scary").first?.prompt,
                       "the look travels as what the writer reads, not as its name")
        XCTAssertNil(payload["narration"], "a voice was chosen, so narration is the style's own")
    }

    /// "No voiceover" is an answer: the story is told on screen, and nobody's
    /// voice id is sent.
    func testNoVoiceoverTurnsNarrationOff() {
        let payload = choice(voice: "none").payload
        XCTAssertEqual(payload["narration"] as? Bool, false)
        XCTAssertNil(payload["voiceId"])
    }

    func testTheSettledLineSaysWhatWasChosen() {
        let summary = choice().summary
        XCTAssertTrue(summary.hasPrefix("Photo video · 30 sec · Scary stories"))
        XCTAssertTrue(summary.contains("Storyteller"))
        XCTAssertTrue(summary.contains("Bold pop"))
        XCTAssertTrue(choice(caption: "none").summary.contains("No captions"))
    }

    /// The button's estimate grows with the length and is cheaper without a
    /// voice -- never zero, because pictures are always made.
    func testTheEstimateFollowsLengthAndVoice() {
        XCTAssertGreaterThan(choice(seconds: 60).estimatedUSD, choice(seconds: 15).estimatedUSD)
        XCTAssertLessThan(choice(voice: "none").estimatedUSD, choice().estimatedUSD)
        XCTAssertGreaterThan(choice(voice: "none", seconds: 15).estimatedUSD, 0)
    }

    /// The action wraps the same payload, so the card and the chat send one
    /// shape.
    func testTheChatActionSendsTheChoice() {
        let action = AppSession.ChatAction.story(choice())
        XCTAssertEqual(action.payload["type"] as? String, "story")
        XCTAssertEqual(action.payload["style"] as? String, "scary")
    }
}
