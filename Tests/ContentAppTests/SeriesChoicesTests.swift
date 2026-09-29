import XCTest
@testable import ContentApp

/// What Start a series asks about how the videos come out, and the two things
/// the video page and the chats list learned on 29 Sep 2026. Each of these is a
/// way the screen was wrong in Abel's hands: a stranded tile in a grid, a
/// greeting made into a video on somebody's credits, a conversation that made
/// a video and did not say so.
final class SeriesChoicesTests: XCTestCase {

    /// Two to a row, and no stranded tile: the rule the style picker was held
    /// to on 24 Sep ("37 styles left a stranded tile"), applied to every grid
    /// this flow draws.
    func testEveryGridHasAnEvenNumberOfTiles() {
        XCTAssertEqual(SeriesLook.all.count % 2, 0, "an odd look would sit alone on the last row")
        XCTAssertEqual(SeriesLanguage.all.count % 2, 0, "an odd language would sit alone on the last row")
    }

    func testEveryChoiceHasItsOwnId() {
        XCTAssertEqual(Set(SeriesLook.all.map(\.id)).count, SeriesLook.all.count)
        XCTAssertEqual(Set(SeriesVoice.all.map(\.id)).count, SeriesVoice.all.count)
        XCTAssertEqual(Set(SeriesLanguage.all.map(\.id)).count, SeriesLanguage.all.count)
    }

    /// A look is sent to the writer and appended to every concept, so it must
    /// say something -- and its picture is found by convention, so the name
    /// the tile looks for has to be the one the asset was imported under.
    func testEveryLookSaysWhatItMeansAndWhereItsPictureLives() {
        for look in SeriesLook.all {
            XCTAssertFalse(look.prompt.isEmpty, "\(look.id) has nothing to tell the writer")
            XCTAssertTrue(look.sentence.hasPrefix(look.name), "the server reads the name first")
            XCTAssertTrue(look.sentence.contains(" -- "), "propose-plan splits the name from the meaning on ' -- '")
            XCTAssertEqual(look.artName, "look-\(look.id)")
        }
    }

    /// "It must be a requirement" -- and "no voiceover" is an answer to it.
    /// Exactly one voice means nobody, and the server recognises it by the
    /// word `none` at the start.
    func testNoVoiceoverIsAnAnswerAndTheOnlyOne() {
        XCTAssertEqual(SeriesVoice.all.filter(\.isNone).count, 1)
        XCTAssertEqual(SeriesVoice.all.first?.id, "none")
        for voice in SeriesVoice.all where !voice.isNone {
            XCTAssertFalse(voice.sentence.hasPrefix("none"), "\(voice.id) would be read as no voice")
        }
    }

    // MARK: - "Hi" is not a video

    /// On the video page, send is generate -- so a greeting would be paid for
    /// and made. These are answered instead.
    func testGreetingsAreNotSubjects() {
        for said in ["Hi", "hi", "Hi!!", "hello", "Hello there.", "hey", "  HEY  ", "thanks", "Thank you!", "ok", "test"] {
            XCTAssertTrue(SmallTalk.matches(said), "\"\(said)\" should be answered, not made")
        }
    }

    /// The composer appends its choices on a new line. They are not part of
    /// what was said.
    func testTheComposersSpecIsNotPartOfWhatWasSaid() {
        XCTAssertTrue(SmallTalk.matches("Hi\n(30 seconds, with a voiceover, with captions)"))
        XCTAssertFalse(SmallTalk.matches("A cat surfing\n(5 seconds, 9:16)"))
    }

    /// A list of exact phrases, never a guess: one word can be a fine video.
    func testARealPromptIsNeverEaten() {
        for said in ["sunset", "a cat surfing", "Hi-tech kitchen gadgets", "hello world in neon", "make a video of my shop", "coffee"] {
            XCTAssertFalse(SmallTalk.matches(said), "\"\(said)\" is something to make")
        }
    }

    // MARK: - The chats list says what a conversation made

    private func thread(kind: String, media: String?) throws -> ChatThread {
        var fields = #""id":"9F0B4A1E-6A34-4C5E-9E52-0E2B3D0A9A11","title":"x","preview":"","updated_at":"2026-09-29T10:00:00Z","kind":"\#(kind)""#
        if let media { fields += #","media":"\#(media)""# }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatThread.self, from: Data("{\(fields)}".utf8))
    }

    func testAThreadThatMadeSomethingSaysWhatItMade() throws {
        XCTAssertEqual(try thread(kind: "generation", media: "video").badge?.title, "Video")
        XCTAssertEqual(try thread(kind: "generation", media: "image").badge?.title, "Image")
        XCTAssertEqual(try thread(kind: "chat", media: "audio").badge?.title, "Audio")
    }

    /// A conversation that made a picture BEFORE threads carried a kind is
    /// still a conversation that made one.
    func testAnOldThreadThatMadeAPictureStillSaysSo() throws {
        let old = try thread(kind: "chat", media: "image")
        XCTAssertEqual(old.badge?.title, "Image")
        XCTAssertTrue(old.isMaking)
        XCTAssertFalse(old.isGeneration, "it was a chat, and reopens as one")
    }

    func testAGeneratorThatHasMadeNothingYetSaysGeneration() throws {
        XCTAssertEqual(try thread(kind: "generation", media: nil).badge?.title, "Generation")
    }

    func testAPlainConversationCarriesNoBadge() throws {
        let plain = try thread(kind: "chat", media: nil)
        XCTAssertNil(plain.badge)
        XCTAssertFalse(plain.isMaking)
    }
}
