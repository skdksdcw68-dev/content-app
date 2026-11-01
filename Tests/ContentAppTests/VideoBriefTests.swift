import XCTest
@testable import ContentApp

/// What the server decides for the create card (`_shared/video/brief.ts`) and
/// what the app does with it. Abel, 1 Nov 2026: "If the user already
/// explained, why does the user have to choose again for anything, bro?"
final class VideoBriefTests: XCTestCase {

    private func offer(brief: String?) throws -> ModelOffer {
        let tail = brief.map { #", "brief": \#($0)"# } ?? ""
        let json = #"{"capability":"video_generation","options":[],"worthAsking":false"# + tail + "}"
        return try JSONDecoder().decode(ModelOffer.self, from: Data(json.utf8))
    }

    func testAnOfferWithoutABriefStillDecodes() throws {
        XCTAssertNil(try offer(brief: nil).brief, "older turns and a failed brief fall back to the old card")
    }

    func testABriefDecodesWithOnlySomeFieldsSet() throws {
        let brief = try XCTUnwrap(offer(brief: #"{"kind":"photo","seconds":20,"style":"apps","captions":"bold_pop"}"#).brief)
        XCTAssertTrue(brief.isPhoto)
        XCTAssertEqual(brief.seconds, 20)
        XCTAssertEqual(brief.style, "apps")
        XCTAssertEqual(brief.captions, "bold_pop")
        XCTAssertNil(brief.voice)
        XCTAssertNil(brief.customLook)
    }

    func testAnAIBriefIsNotAPhotoVideo() throws {
        let brief = try XCTUnwrap(offer(brief: #"{"kind":"ai"}"#).brief)
        XCTAssertFalse(brief.isPhoto)
    }

    /// A look written for the video is used as written, under the name the
    /// server gave it; without a name the card says where it came from.
    func testALookWrittenForTheVideoBecomesTheCardsLook() throws {
        let named = try XCTUnwrap(offer(brief: #"{"kind":"photo","look":"bright kitchen light, soft shadows","lookName":"Bright kitchen"}"#).brief)
        XCTAssertEqual(named.customLook?.name, "Bright kitchen")
        XCTAssertEqual(named.customLook?.prompt, "bright kitchen light, soft shadows")
        let unnamed = try XCTUnwrap(offer(brief: #"{"kind":"photo","look":"bright kitchen light"}"#).brief)
        XCTAssertEqual(unnamed.customLook?.name, "Matched to your request")
        let none = try XCTUnwrap(offer(brief: #"{"kind":"photo","look":""}"#).brief)
        XCTAssertNil(none.customLook, "an empty look is no look")
    }

    /// The server's direction reaches the writer only through the story
    /// action, so it has to be in the payload -- and absent when empty.
    func testTheDirectionTravelsWithTheStory() {
        var choice = StoryChoice(
            style: "apps", styleName: "Apps", topic: "a calorie tracker", seconds: 20,
            look: nil, voice: nil, caption: SeriesCaption.all[0],
            direction: "Open on a half-eaten plate. Calm, no hard sell."
        )
        XCTAssertEqual(choice.payload["direction"] as? String, "Open on a half-eaten plate. Calm, no hard sell.")
        choice.direction = ""
        XCTAssertNil(choice.payload["direction"])
        choice.direction = nil
        XCTAssertNil(choice.payload["direction"])
    }
}
