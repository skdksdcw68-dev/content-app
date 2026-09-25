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

    private static let video: [Entry] = [
        Entry(id: "veo3_1", name: "Google Veo 3.1",
              about: "Realistic, follows the prompt closely, makes its own sound.", frames: true),
        Entry(id: "veo3_1_lite", name: "Google Veo 3.1 Lite",
              about: "Like Veo 3.1, faster and cheaper.", frames: true),
        Entry(id: "/sora-2/text-to-video", name: "Sora 2",
              about: "Strong movement and camera work, with sound.", frames: false),
        Entry(id: "/sora-2/text-to-video/pro", name: "Sora 2 Pro",
              about: "Sora at its best, for the shot that matters.", frames: false),
        Entry(id: "kling3_0", name: "Kling v3.0",
              about: "Steady motion and faces that hold together.", frames: true),
        Entry(id: "kling3_0_turbo", name: "Kling 3.0 Turbo",
              about: "Kling, quicker, for trying things out.", frames: true),
        Entry(id: "seedance_2_0", name: "Seedance 2.0",
              about: "Good with people moving and dancing.", frames: true),
        Entry(id: "seedance_2_0_mini", name: "Seedance 2.0 Mini",
              about: "The cheap one for rough cuts.", frames: true),
        Entry(id: "minimax_h3", name: "MiniMax H3",
              about: "Clean, simple shots that do what they are told.", frames: true),
        Entry(id: "wan3_0", name: "Wan 3.0",
              about: "Sharp detail, good for products.", frames: true),
    ]

    private static let image: [Entry] = [
        Entry(id: "nano_banana_pro", name: "Google Nano Banana Pro",
              about: "Studio quality, legible text, very consistent.", frames: false),
        Entry(id: "nano_banana_2", name: "Google Nano Banana 2",
              about: "Knows the world, precise text, fast.", frames: false),
        Entry(id: "nano_banana", name: "Google Nano Banana",
              about: "Quick, high-quality generation and editing.", frames: false),
        Entry(id: "seedream_v5_pro", name: "Seedream 5.0 Pro",
              about: "Rich, photographic, good with people.", frames: false),
        Entry(id: "soul_2", name: "Higgsfield Soul 2.0",
              about: "Stylised and cinematic rather than literal.", frames: false),
        Entry(id: "recraft_v4_1", name: "Recraft V4.1",
              about: "Built for graphics, logos and flat art.", frames: false),
        Entry(id: "z_image", name: "Z Image",
              about: "Fast and cheap, for trying a composition.", frames: false),
    ]

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
