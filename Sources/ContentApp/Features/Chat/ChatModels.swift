import Foundation

/// One thing the agent actually did, while it was doing it.
///
/// A single line saying "Thinking" for eleven seconds is the same screen
/// whether the agent is reading your brand three times or has stalled, and the
/// reader cannot tell which. So the work arrives as steps, each one ticking as
/// it finishes.
///
/// The guarantee that a step cannot claim work that did not happen lives on the
/// server, which is the only place that can honour it: `agent-chat` emits a
/// step *after* the read it describes has returned, and counts what it counted.
/// This type is a faithful carrier and deliberately nothing more -- there is no
/// convenience initialiser here for composing a plausible-sounding line.
struct TaskStep: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case reading
        case writing
        case planning

        var symbol: String {
            switch self {
            case .reading:  "text.alignleft"
            case .writing:  "square.and.pencil"
            case .planning: "calendar"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let detail: String
    var isDone = false

    /// Built only from what the server reported.
    init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    /// One line for the whole trail, once it is folded away.
    static func summary(of steps: [TaskStep]) -> String {
        steps.count == 1 ? "1 step" : "\(steps.count) steps"
    }
}

/// Something the agent needs to know before it will spend anything.
///
/// Sent as data rather than as a numbered list in the reply. The answers come
/// back as values the strategy is built from, and parsing them out of a
/// sentence is how the wrong month gets built.
struct ChatQuestion: Identifiable, Equatable, Decodable {
    struct Option: Identifiable, Equatable, Decodable {
        var id: String { value }
        let value: String
        let label: String
    }

    var id: String { key }
    let key: String
    let prompt: String
    let options: [Option]
    /// Every question takes a typed answer too. The buttons are a shortcut, not
    /// a cage: somebody whose goal is not on the list should not have to pick
    /// the nearest wrong one.
    let allowsFreeText: Bool

    private enum CodingKeys: String, CodingKey {
        case key, prompt, options
        case allowsFreeText
    }
}

/// What a provider charges, in whatever unit it actually charges in.
///
/// Not a number, because the units genuinely differ: credits, tokens, per
/// second of output, or an allowance already paid for. `unknown` is the common
/// case and is shown as "Cost not stated" — never as zero, because free and
/// unknown are different facts and only one is safe to act on.
struct ModelCost: Equatable, Decodable {
    let unit: String
    let amount: Double?
    let basis: String?
    let quoted: Bool

    var label: String {
        guard let amount, unit != "unknown" else { return "Cost not stated" }
        switch unit {
        case "allowance": return "Included in your plan"
        case "usd":       return String(format: "$%.2f", amount)
        default:          return "\(formatted(amount)) \(unit)"
        }
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// What a model will actually accept. Every field optional, because a provider
/// that does not say is different from one that says "any", and inventing a
/// range would be worse than the gap.
struct ModelConstraints: Equatable, Decodable {
    var durations: [Int]?
    var resolutions: [String]?
    var aspectRatios: [String]?
    var formats: [String]?
    var typicalSeconds: Int?
    var notes: [String]?
}

/// One model the agent found, offered as a choice.
struct ModelChoice: Identifiable, Equatable, Decodable {
    var id: String { modelId }
    let modelId: String
    let provider: String
    let label: String
    let externalId: String
    let cost: ModelCost
    let constraints: ModelConstraints
    let reason: String?
    let recommended: Bool
}

/// Everything the agent found for one capability.
struct ModelOffer: Equatable, Decodable {
    let capability: String
    let options: [ModelChoice]
    let worthAsking: Bool
    let auto: ModelChoice?
}

/// One turn in the conversation.
///
/// The user's turn is a tinted capsule pushed right; the agent's is typography
/// on the page. Boxing a long answer makes it read as a quotation rather than a
/// reply, which is why every assistant on the platform sets it this way.
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    /// Shown as the working state until the first token lands.
    var isPending = false
    /// What the agent did on this turn, in order. Live while it works, kept
    /// afterwards so the path to an answer stays checkable.
    var steps: [TaskStep] = []
    /// What it needs answered before it will go and spend money.
    var questions: [ChatQuestion] = []
    /// The models it found, when a choice is worth making.
    var offer: ModelOffer? = nil
    /// Which one was taken, once somebody picked or Auto decided.
    var chosenModel: String? = nil
    /// Which of those have been answered, so a tapped card settles rather than
    /// sitting there inviting the same tap again.
    var answered: [String: String] = [:]
    var failed = false

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text)
    }

    static var thinking: ChatMessage {
        ChatMessage(role: .assistant, text: "", isPending: true)
    }
}
