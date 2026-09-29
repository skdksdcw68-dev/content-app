import XCTest
@testable import ContentApp

/// What the composer sends, and which controls it draws, for each kind of
/// model. Every one of these is a way the generator was wrong on 29 Sep 2026:
/// the size, the negative prompt and the pixels never left the phone, Kling was
/// offered a resolution it does not have, and two switches -- Voiceover and
/// Captions -- were sent nowhere at all.
final class GenerateChoicesTests: XCTestCase {

    // MARK: - Models, as the server describes them

    /// Kling 2.5 Turbo: two lengths, no pixels setting, no sound, an end frame.
    private static let kling = #"""
    {"durations":[5,10],"resolutions":[],"aspectRatios":["9:16","1:1","16:9"],
     "audio":false,"takesPicture":true,"endFrame":true,"negativePrompt":true,"pictureAspect":false}
    """#

    /// Veo 3.1: three lengths, three pixel sizes, its own sound, two shapes.
    private static let veo = #"""
    {"durations":[4,6,8],"resolutions":["720p","1080p","4k"],"aspectRatios":["9:16","16:9"],
     "audio":true,"takesPicture":true,"endFrame":false,"negativePrompt":true,"pictureAspect":true,
     "defaults":{"resolution":"720p","duration":4}}
    """#

    /// A picture model that does not read a negative prompt.
    private static let flux = #"""
    {"aspectRatios":["9:16","4:5","1:1","16:9"],"resolutions":[],
     "audio":false,"takesPicture":false,"endFrame":false,"negativePrompt":false}
    """#

    private func model(_ id: String, _ constraints: String) throws -> ModelChoice {
        let decoded = try JSONDecoder().decode(ModelConstraints.self, from: Data(constraints.utf8))
        return ModelChoice(
            modelId: id,
            provider: "fal",
            label: id,
            externalId: id,
            cost: ModelCost(unit: "usd", amount: 0.1, basis: nil, quoted: false),
            constraints: decoded,
            reason: nil,
            recommended: false,
            affordable: nil,
            badges: nil,
            family: nil,
            about: nil,
            suitable: true
        )
    }

    // MARK: - What is sent

    /// Kling has no `resolution` field, so sending one is a 422 or a lie. The
    /// bar shows no pixels control for it either.
    func testAModelWithNoPixelsSettingSendsNoResolution() throws {
        var choices = GenerateChoices()
        choices.model = try model("kling", Self.kling)
        choices.fit()

        XCTAssertTrue(choices.resolutions.isEmpty)
        XCTAssertNil(choices.settings.resolution)
    }

    /// Sound is the biggest cost lever (Veo is half the price without it), so it
    /// is sent explicitly where the model has it -- and not at all where it does
    /// not.
    func testSoundIsSentWhereTheModelHasItAndOnlyThere() throws {
        var veo = GenerateChoices()
        veo.model = try model("veo", Self.veo)
        XCTAssertTrue(veo.hasSound)
        XCTAssertEqual(veo.settings.extras["generate_audio"], "true")
        veo.audio = false
        XCTAssertEqual(veo.settings.extras["generate_audio"], "false")

        var kling = GenerateChoices()
        kling.model = try model("kling", Self.kling)
        XCTAssertFalse(kling.hasSound)
        XCTAssertNil(kling.settings.extras["generate_audio"])
    }

    /// The shape was on the bar and stayed on the phone, so "9:16" was a label
    /// and a 1:1 video came back 16:9.
    func testTheShapeAlwaysTravels() throws {
        var choices = GenerateChoices()
        choices.model = try model("veo", Self.veo)
        XCTAssertEqual(choices.settings.extras["aspect_ratio"], "9:16")

        choices.aspect = "16:9"
        XCTAssertEqual(choices.settings.extras["aspect_ratio"], "16:9")
    }

    func testTheNegativePromptTravelsOnlyWhereItIsUnderstood() throws {
        var video = GenerateChoices()
        video.model = try model("veo", Self.veo)
        video.negative = "  blurry  "
        XCTAssertEqual(video.settings.extras["negative_prompt"], "blurry")

        var picture = GenerateChoices()
        picture.mode = .image
        picture.model = try model("flux", Self.flux)
        picture.negative = "blurry"
        XCTAssertFalse(picture.takesNegative)
        XCTAssertNil(picture.settings.extras["negative_prompt"])
    }

    /// A picture has no length, and a length sent with one is noise.
    func testAPictureSendsNoDuration() throws {
        var choices = GenerateChoices()
        choices.mode = .image
        choices.model = try model("flux", Self.flux)
        XCTAssertNil(choices.settings.duration)
        XCTAssertFalse(choices.hasSound)
    }

    // MARK: - Fitting to the model

    /// Choosing Veo after Wan must not leave "480p", 5 seconds and 1:1 selected
    /// on a model that has none of them.
    func testChangingModelMovesWhatNoLongerApplies() throws {
        var choices = GenerateChoices()
        choices.resolution = "480p"
        choices.seconds = 5
        choices.aspect = "1:1"

        choices.model = try model("veo", Self.veo)
        choices.fit()

        XCTAssertEqual(choices.resolution, "720p")
        XCTAssertTrue([4, 6].contains(choices.seconds), "the nearest length Veo makes")
        XCTAssertEqual(choices.aspect, "9:16")
    }

    /// What still applies is kept: a length and a shape the new model also
    /// makes are the person's choice, not something to reset.
    func testWhatStillAppliesIsKept() throws {
        var choices = GenerateChoices()
        choices.seconds = 10
        choices.aspect = "16:9"

        choices.model = try model("kling", Self.kling)
        choices.fit()

        XCTAssertEqual(choices.seconds, 10)
        XCTAssertEqual(choices.aspect, "16:9")
    }

    // MARK: - The size, when a picture is in play

    /// A video from a picture takes the picture's shape, so there is nothing to
    /// choose. A picture being edited has no such rule.
    func testAPictureDecidesTheShapeOfAVideoButNotOfAPicture() {
        var video = GenerateChoices()
        XCTAssertTrue(video.choosesShape)
        video.pictured = true
        XCTAssertFalse(video.choosesShape)

        var picture = GenerateChoices()
        picture.mode = .image
        picture.pictured = true
        XCTAssertTrue(picture.choosesShape)
    }

    func testAnEndFrameIsOfferedOnlyWhereTheModelHasOne() throws {
        var kling = GenerateChoices()
        kling.model = try model("kling", Self.kling)
        XCTAssertTrue(kling.takesEndFrame)

        var veo = GenerateChoices()
        veo.model = try model("veo", Self.veo)
        XCTAssertFalse(veo.takesEndFrame)

        var picture = GenerateChoices()
        picture.mode = .image
        picture.model = try model("kling", Self.kling)
        XCTAssertFalse(picture.takesEndFrame, "frames are a video's")
    }

    // MARK: - The voiceover

    /// Only a model that makes its own sound can speak a line, so only there is
    /// the line added to the prompt. A switch that changes nothing is a lie the
    /// size of a switch.
    func testTheVoiceoverIsSpokenOnlyByAModelThatMakesSound() throws {
        var veo = GenerateChoices()
        veo.model = try model("veo", Self.veo)
        veo.voiceover = "Welcome to the shop"
        XCTAssertTrue(veo.canSpeak)
        XCTAssertEqual(veo.prompt("a barista"), "a barista\n\nA narrator says: \"Welcome to the shop\"")

        veo.audio = false
        XCTAssertFalse(veo.canSpeak)
        XCTAssertEqual(veo.prompt("a barista"), "a barista")

        var kling = GenerateChoices()
        kling.model = try model("kling", Self.kling)
        kling.voiceover = "Welcome to the shop"
        XCTAssertFalse(kling.canSpeak)
        XCTAssertEqual(kling.prompt("a barista"), "a barista")
    }

    func testAnEmptyVoiceoverAddsNothing() {
        XCTAssertEqual(GenerateChoices.adding(voiceover: "   ", to: "a barista"), "a barista")
    }

    /// Quotes inside the line would close the one around it.
    func testQuotesInsideTheVoiceoverAreSoftened() {
        let prompt = GenerateChoices.adding(voiceover: "Say \"hi\"", to: "a barista")
        XCTAssertEqual(prompt, "a barista\n\nA narrator says: \"Say 'hi'\"")
    }

    // MARK: - The card and the labels

    /// The card sets a few things itself; everything else in `extras` is the
    /// model's own question -- a voice, an engine -- and is what the transcript
    /// summary names.
    func testTheCardsOwnKeysAreKeptApartFromTheModelsQuestions() {
        let settings = GenerationSettings(
            resolution: "720p",
            duration: 5,
            quality: nil,
            extras: ["aspect_ratio": "9:16", "generate_audio": "true", "negative_prompt": "blur", "voice": "Ashley"]
        )
        XCTAssertEqual(settings.answers, ["voice": "Ashley"])
    }

    func testPixelsAreReadAsPixels() {
        XCTAssertEqual(GenerateChoices.pixelsLabel("4k"), "4K")
        XCTAssertEqual(GenerateChoices.pixelsLabel("768"), "768p")
        XCTAssertEqual(GenerateChoices.pixelsLabel("720p"), "720p")
        XCTAssertEqual(GenerateChoices.pixelsLabel("0.5K"), "0.5K")
    }
}
