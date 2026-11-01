import XCTest
@testable import ContentApp

/// Several pictures from one request. Abel, 1 Nov 2026: "When you ask it to
/// create or generate 4 different images or 10 images, it actually generates a
/// split image on a single photo."
final class ImageSetTests: XCTestCase {

    func testTheOfferCarriesHowManyPictures() throws {
        let json = #"{"capability":"image_generation","options":[],"worthAsking":true,"settings":{"count":4,"aspect_ratio":"3:4"}}"#
        let offer = try JSONDecoder().decode(ModelOffer.self, from: Data(json.utf8))
        XCTAssertEqual(offer.settings?.count, 4)
        XCTAssertEqual(offer.settings?.aspectRatio, "3:4")
    }

    func testAnOfferWithoutACountIsOnePicture() throws {
        let json = #"{"capability":"image_generation","options":[],"worthAsking":true,"settings":{}}"#
        let offer = try JSONDecoder().decode(ModelOffer.self, from: Data(json.utf8))
        XCTAssertNil(offer.settings?.count)
    }

    /// The count rides in the settings sent with Generate, but it is the
    /// card's own setting, not a model's answer: it must not turn up in the
    /// settled line as a bare "4".
    func testTheCountIsNotReadAsAModelsAnswer() {
        var settings = GenerationSettings()
        settings.extras["count"] = "4"
        settings.extras["voice"] = "Ava"
        XCTAssertEqual(settings.payload["count"] as? String, "4", "the server reads it from here")
        XCTAssertNil(settings.answers["count"])
        XCTAssertEqual(settings.answers["voice"], "Ava")
    }
}
