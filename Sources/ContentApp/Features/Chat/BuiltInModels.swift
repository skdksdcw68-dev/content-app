import Foundation

/// The models Autocast offers, written down.
///
/// Abel, 25 Sep 2026: "instead of asking users to connect with connector who
/// even doesnt knows thats that then what if we make our own? So they just
/// choose a model we have... lets hardcode models for now and we move for
/// them."
///
/// He is right about the user-facing half. Nobody signing up to post videos
/// knows what MCP is, and a picker that says "connect a generator from the
/// plus menu" is asking them to go and solve our problem. Autocast brings the
/// models; the person picks one.
///
/// SO WHY IS THIS A FALLBACK AND NOT THE WHOLE LIST. The forty-one real ones
/// come from the house connection and carry live prices and real constraints.
/// A written-down list cannot know what a job costs today. This stands in
/// when discovery has nothing to say -- a cold start, a flat network, or the
/// provider having a bad minute -- so the screen is never empty and never
/// mentions a connector.
///
/// THE IDS ARE REAL. Every `externalId` below was read off the house
/// connection's own catalogue on 25 Sep 2026, so picking one here sends the
/// same string discovery would have sent, and it generates. A made-up id
/// would give somebody a list that looks fine and fails on send.
extension ModelConstraints {
    /// Nothing known. `ModelConstraints` declares `init(from:)` in its body,
    /// which suppresses the memberwise and empty initialisers; this puts an
    /// empty one back for the written-down list, which genuinely knows none of
    /// a model's limits.
    static var unknown: ModelConstraints {
        // Decoding an empty object is the only way in, and it cannot fail:
        // every field is optional and read with `try?`.
        try! JSONDecoder().decode(ModelConstraints.self, from: Data("{}".utf8))
    }
}

enum BuiltInModels {
    static func forCapability(_ capability: String) -> [ModelChoice] {
        (capability == "image_generation" ? image : video).map(\.choice)
    }

    /// One written-down model.
    private struct Entry {
        let id: String
        let name: String
        let about: String
        /// Takes a first and last frame, so the composer can offer them.
        let frames: Bool

        var choice: ModelChoice {
            ModelChoice(
                modelId: id,
                provider: "fal",
                label: name,
                externalId: id,
                // No price. Writing one down would be inventing a number, and
                // this list exists precisely when nothing can be quoted.
                cost: ModelCost(unit: "unknown", amount: nil, basis: nil, quoted: false),
                constraints: ModelConstraints.unknown,
                reason: nil,
                recommended: false,
                affordable: nil,
                badges: nil,
                family: nil,
                about: about,
                suitable: true
            )
        }
    }

    /// 🔴 These were Higgsfield's ids -- `veo3_1`, `kling3_0` -- written when
    /// Higgsfield was the house generator. It is fal now, and fal has never
    /// heard of any of them, so this list would have shown a picker full of
    /// models that fail the moment one is chosen. Exactly the fault the
    /// comment at the top of this file warns about, committed in the same
    /// hour. Read off the fal adapter's own catalogue.
    private static let video: [Entry] = [
        // 18 Oct 2026: re-read off the adapter. Wan 2.5 and Kling 2.1 Master
        // had left the catalogue on 29 Sep, so picking either here failed on
        // send ("not a model this generator offers"); Veo 3.1 leaves fal on
        // 17 Nov and Gemini Omni takes its place.
        Entry(id: "alibaba/wan-3.0/text-to-video", name: "Wan 3.0",
              about: "Sharp and cheap, with sound. The everyday choice.", frames: true),
        Entry(id: "fal-ai/kling-video/v2.5-turbo/pro/text-to-video", name: "Kling 2.5 Turbo Pro",
              about: "Steady motion and faces that hold together.", frames: true),
        Entry(id: "google/gemini-omni-flash/v1.1/text-to-video", name: "Google Gemini Omni Flash",
              about: "Google's newest, after Veo. Makes its own sound.", frames: true),
        Entry(id: "fal-ai/kling-video/v3/pro/text-to-video", name: "Kling 3.0 Pro",
              about: "Kling's newest, with native sound.", frames: true),
        Entry(id: "bytedance/seedance-2.0/fast/text-to-video", name: "Seedance 2.0 Fast",
              about: "Cinematic motion with sound, quick to make.", frames: true),
    ]

    /// The everyday picture models the adapter offers (29 Sep 2026 on), for a
    /// cold start. Each id is the adapter's own.
    private static let image: [Entry] = [
        Entry(id: "fal-ai/nano-banana", name: "Google Nano Banana",
              about: "Quick, high-quality generation and editing.", frames: false),
        Entry(id: "openai/gpt-image-2", name: "GPT Image 2",
              about: "The most accurate, and the best with text.", frames: false),
        Entry(id: "bytedance/seedream/v5/pro/text-to-image", name: "Seedream 5 Pro",
              about: "Photographic, great with people and products.", frames: false),
        Entry(id: "fal-ai/flux/schnell", name: "FLUX Schnell",
              about: "The quick one. Good for trying a composition.", frames: false),
    ]

    /// Whether a video model can start from a picture, so the composer offers a
    /// start frame -- Abel: "the start and end frame thing when it comes to
    /// model that supports it". (Whether it takes a LAST frame too is a
    /// separate question, `GenerateChoices.takesEndFrame`.)
    ///
    /// The model's own word first (29 Sep 2026: every model in the house
    /// catalogue now says), then the written-down list, then a guess from the
    /// id for a discovered model that is on neither. The guess is conservative:
    /// the families known to take frames, and nothing else.
    static func takesFrames(_ model: ModelChoice?) -> Bool {
        guard let model else { return false }
        if let own = model.constraints.takesPicture { return own }
        if let entry = (video + image).first(where: { $0.id == model.externalId }) {
            return entry.frames
        }
        let id = model.externalId.lowercased()
        return id.contains("kling") || id.contains("veo") || id.contains("seedance")
            || id.contains("wan") || id.contains("minimax") || id.contains("hailuo")
    }
}
