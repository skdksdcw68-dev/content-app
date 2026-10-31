import XCTest
@testable import ContentApp

/// What a request already says about its video, so the card does not ask
/// again. Abel, 31 Oct 2026: "If the user says, 'Generate 15 seconds,' make
/// sure it's only 15 seconds."
final class VideoAskTests: XCTestCase {

    func testLengthsAreReadHoweverTheyAreWritten() {
        XCTAssertEqual(VideoAsk.read("Generate 15 seconds about my closet").seconds, 15)
        XCTAssertEqual(VideoAsk.read("a 15s scary video").seconds, 15)
        XCTAssertEqual(VideoAsk.read("make a 20-second video").seconds, 20)
        XCTAssertEqual(VideoAsk.read("30 sec reel please").seconds, 30)
        XCTAssertEqual(VideoAsk.read("one minute video about stoics").seconds, 60)
        XCTAssertEqual(VideoAsk.read("1.5 min story").seconds, 90)
        XCTAssertEqual(VideoAsk.read("fifteen seconds of motivation").seconds, 15)
        XCTAssertEqual(VideoAsk.read("give me a minute long story").seconds, 60)
        XCTAssertEqual(VideoAsk.read("half a minute is enough").seconds, 30)
    }

    func testWordsThatOnlyLookLikeLengthsAreNotLengths() {
        XCTAssertNil(VideoAsk.read("make 3 scenes about my app").seconds)
        XCTAssertNil(VideoAsk.read("10 stories nobody tells").seconds)
        XCTAssertNil(VideoAsk.read("5 secrets of sleep").seconds)
        XCTAssertNil(VideoAsk.read("make me a scary video").seconds)
        XCTAssertNil(VideoAsk.read(nil).seconds)
    }

    func testALengthIsKeptInsideWhatAStoryCanBe() {
        XCTAssertEqual(VideoAsk.read("a 2 second video").seconds, 5)
        XCTAssertEqual(VideoAsk.read("a 10 minute video").seconds, 180)
    }

    func testTheKindIsTakenOnlyWhenTheRequestSaysIt() {
        XCTAssertEqual(VideoAsk.read("make a photo video about ghosts").kind, .photo)
        XCTAssertEqual(VideoAsk.read("a slideshow of my products").kind, .photo)
        XCTAssertEqual(VideoAsk.read("a video made from pictures").kind, .photo)
        XCTAssertEqual(VideoAsk.read("make an AI video of a cat surfing").kind, .ai)
        XCTAssertEqual(VideoAsk.read("use kling for this").kind, .ai)
        XCTAssertNil(VideoAsk.read("make me a video about my closet").kind, "not said, so the card asks")
    }

    func testARequestNamesAStyleBySlugOrByItsName() {
        let scary = ContentTemplate.preview(slug: "scary", name: "Scary stories")
        let motivation = ContentTemplate.preview(slug: "motivation", name: "Motivation")
        let ai = ContentTemplate.preview(slug: "aitools", name: "AI tools")
        XCTAssertTrue(CreateVideoCard.mentions("a scary one about a closet", style: scary))
        XCTAssertTrue(CreateVideoCard.mentions("something motivational", style: motivation))
        XCTAssertFalse(CreateVideoCard.mentions("make an ai video", style: ai), "two letters are too common to mean the style")
    }
}

private extension ContentTemplate {
    static func preview(slug: String, name: String) -> ContentTemplate {
        ContentTemplate(slug: slug, name: name, tagline: "", category: "", symbol: "sparkles",
                        art: nil, pillars: [], visualStyle: "", workflow: nil)
    }
}
