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
                provider: "higgsfield",
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
        Entry(id: "fal-ai/wan-25-preview/text-to-video", name: "Wan 2.5",
              about: "Sharp and cheap. The everyday choice for a short clip.", frames: true),
        Entry(id: "fal-ai/kling-video/v2.5-turbo/pro/text-to-video", name: "Kling 2.5 Turbo Pro",
              about: "Steady motion and faces that hold together.", frames: false),
        Entry(id: "fal-ai/veo3.1/fast", name: "Google Veo 3.1 Fast",
              about: "Realistic, follows the prompt closely, makes its own sound.", frames: false),
        Entry(id: "fal-ai/kling-video/v2.1/master/text-to-video", name: "Kling 2.1 Master",
              about: "Kling at full quality, for the shot that matters.", frames: false),
        Entry(id: "fal-ai/veo3.1", name: "Google Veo 3.1",
              about: "The best of them, with audio. Costs what that implies.", frames: false),
    ]

    /// Empty on purpose. The house generator offers no image models yet, and
    /// the Higgsfield ids that used to be here would fail on the first tap.
    /// An empty picker that says so is honest; a full one that does not work
    /// is not. Fills in the day the adapter declares image models.
    private static let image: [Entry] = []

    /// Whether a model takes a first and last frame. Used by the composer to
    /// decide whether to offer them -- Abel: "the start and end frame thing
    /// when it comes to model that supports it".
    ///
    /// Read off the written-down list first, then guessed from the id for a
    /// discovered model that is not on it. The guess is conservative: the
    /// families known to take frames, and nothing else.
    static func takesFrames(_ model: ModelChoice?) -> Bool {
        guard let model else { return false }
        if let entry = (video + image).first(where: { $0.id == model.externalId }) {
            return entry.frames
        }
        let id = model.externalId.lowercased()
        return id.contains("kling") || id.contains("veo") || id.contains("seedance")
            || id.contains("wan") || id.contains("minimax") || id.contains("hailuo")
    }
}
