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
/// range would be worse than the gap. Read leniently, field by field: one odd
/// value from a provider must not stop the whole card from drawing.
struct ModelConstraints: Equatable, Decodable {
    struct Defaults: Equatable, Decodable {
        var resolution: String?
        var duration: Double?
        var quality: String?
    }

    var durations: [Double]?
    var resolutions: [String]?
    /// A quality tier some models offer instead of a resolution.
    var qualities: [String]?
    var aspectRatios: [String]?
    var typicalSeconds: Int?
    var notes: [String]?
    var defaults: Defaults?

    private enum CodingKeys: String, CodingKey {
        case durations, resolutions, qualities, aspectRatios, typicalSeconds, notes, defaults
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        durations = try? c.decodeIfPresent([Double].self, forKey: .durations)
        resolutions = try? c.decodeIfPresent([String].self, forKey: .resolutions)
        qualities = try? c.decodeIfPresent([String].self, forKey: .qualities)
        aspectRatios = try? c.decodeIfPresent([String].self, forKey: .aspectRatios)
        typicalSeconds = try? c.decodeIfPresent(Int.self, forKey: .typicalSeconds)
        notes = try? c.decodeIfPresent([String].self, forKey: .notes)
        defaults = try? c.decodeIfPresent(Defaults.self, forKey: .defaults)
    }
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
    /// False when it costs more than the account has.
    let affordable: Bool?
    /// "Cheapest", "Popular".
    let badges: [String]?
}

/// What the person already asked for in words -- "2k", "5 seconds" -- so the
/// card starts on it.
struct OfferSettings: Equatable, Decodable {
    var resolution: String?
    var duration: Double?
    var aspectRatio: String?

    private enum CodingKeys: String, CodingKey {
        case resolution, duration
        case aspectRatio = "aspect_ratio"
    }
}

/// Everything the agent found for one capability.
struct ModelOffer: Equatable, Decodable {
    let capability: String
    let options: [ModelChoice]
    let worthAsking: Bool
    let auto: ModelChoice?
    /// The model the card starts on: one they named, or Auto's pick.
    let preselect: String?
    let settings: OfferSettings?
}

/// What was set on the Generate card, sent with the job.
struct GenerationSettings: Equatable {
    var resolution: String?
    var duration: Double?
    var quality: String?

    var payload: [String: Any] {
        var out: [String: Any] = [:]
        if let resolution { out["resolution"] = resolution }
        if let duration { out["duration"] = Int(duration.rounded()) }
        if let quality { out["quality"] = quality }
        return out
    }
}

/// Something the agent made: a report, a file, an image, a video.
///
/// An object rather than text in a message, so it can be opened, exported,
/// animated and referred to later as "that report". Read-only from here -- the
/// agent writes these and the app shows them, because a result the app could
/// write is a result it could forge.
struct Artifact: Identifiable, Equatable, Decodable {
    struct Finding: Equatable, Decodable {
        let question: String
        let answer: String
    }

    struct Packed: Equatable, Decodable {
        let path: String
        let size: Int
    }

    /// One content theme in a campaign, and how much of it there is.
    struct Pillar: Equatable, Decodable {
        let name: String
        let share: Int
        let why: String
    }

    /// What each kind carries. Every field optional and read leniently: one
    /// kind's shape must never stop another kind's card from drawing.
    struct Body: Equatable, Decodable {
        var summary: String?
        var findings: [Finding]?
        var filename: String?
        var format: String?
        var manifest: [Packed]?
        var prompt: String?
        var modelLabel: String?
        var seconds: Double?
        var width: Int?
        var height: Int?
        var resolution: String?
        var sourceTitle: String?
        // A campaign's strategy.
        var strategyId: UUID?
        var request: String?
        var days: Int?
        var cadence: Int?
        var goal: String?
        var audience: String?
        var appetite: String?
        var angle: String?
        var pillars: [Pillar]?

        private enum CodingKeys: String, CodingKey {
            case summary, findings, filename, format, manifest, prompt, seconds, width, height, resolution
            case request, days, cadence, goal, audience, appetite, angle, pillars
            case modelLabel = "model_label"
            case sourceTitle = "source_title"
            case strategyId = "strategy_id"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summary = try? c.decodeIfPresent(String.self, forKey: .summary)
            findings = try? c.decodeIfPresent([Finding].self, forKey: .findings)
            filename = try? c.decodeIfPresent(String.self, forKey: .filename)
            format = try? c.decodeIfPresent(String.self, forKey: .format)
            manifest = try? c.decodeIfPresent([Packed].self, forKey: .manifest)
            prompt = try? c.decodeIfPresent(String.self, forKey: .prompt)
            modelLabel = try? c.decodeIfPresent(String.self, forKey: .modelLabel)
            seconds = try? c.decodeIfPresent(Double.self, forKey: .seconds)
            width = try? c.decodeIfPresent(Int.self, forKey: .width)
            height = try? c.decodeIfPresent(Int.self, forKey: .height)
            resolution = try? c.decodeIfPresent(String.self, forKey: .resolution)
            sourceTitle = try? c.decodeIfPresent(String.self, forKey: .sourceTitle)
            strategyId = try? c.decodeIfPresent(UUID.self, forKey: .strategyId)
            request = try? c.decodeIfPresent(String.self, forKey: .request)
            days = try? c.decodeIfPresent(Int.self, forKey: .days)
            cadence = try? c.decodeIfPresent(Int.self, forKey: .cadence)
            goal = try? c.decodeIfPresent(String.self, forKey: .goal)
            audience = try? c.decodeIfPresent(String.self, forKey: .audience)
            appetite = try? c.decodeIfPresent(String.self, forKey: .appetite)
            angle = try? c.decodeIfPresent(String.self, forKey: .angle)
            pillars = try? c.decodeIfPresent([Pillar].self, forKey: .pillars)
        }
    }

    /// What the provider said it charged, in its own unit. Absent far more
    /// often than present, and shown only when present.
    struct Charged: Equatable, Decodable {
        let unit: String?
        let amount: Double?
    }

    let id: UUID
    let kind: String
    let title: String
    let status: String
    let version: Int
    let parentId: UUID?
    let storagePath: String?
    let mime: String?
    let byteSize: Int?
    let body: Body
    let provider: String?
    let model: String?
    let actualCost: Charged?
    /// The price shown before it was made -- what the Generate card said.
    let estimatedCost: Charged?

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, status, version, mime, body, provider, model
        case parentId = "parent_id"
        case storagePath = "storage_path"
        case byteSize = "byte_size"
        case actualCost = "actual_cost"
        case estimatedCost = "estimated_cost"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "ready"
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        parentId = try? c.decodeIfPresent(UUID.self, forKey: .parentId)
        storagePath = try? c.decodeIfPresent(String.self, forKey: .storagePath)
        mime = try? c.decodeIfPresent(String.self, forKey: .mime)
        byteSize = try? c.decodeIfPresent(Int.self, forKey: .byteSize)
        body = (try? c.decode(Body.self, forKey: .body)) ?? Body()
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        actualCost = try? c.decodeIfPresent(Charged.self, forKey: .actualCost)
        estimatedCost = try? c.decodeIfPresent(Charged.self, forKey: .estimatedCost)
    }

    /// "84 KB", "3.2 MB". Nil when the size is not known yet.
    var sizeLabel: String? {
        byteSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
}

/// One thing that happened on a long run, as the worker recorded it.
///
/// Replayed from `run_events` by sequence number, so a card that was off
/// screen -- or an app that was closed -- catches up by asking for what came
/// after the last one it drew.
struct RunEvent: Decodable, Equatable {
    struct Payload: Decodable, Equatable {
        var step: String?
        var detail: String?
        var done: Int?
        var of: Int?
        var status: String?
        var error: String?
        var artifactId: UUID?

        private enum CodingKeys: String, CodingKey { case step, detail, done, of, status, error, result }
        private enum ResultKeys: String, CodingKey { case artifactId = "artifact_id" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            step = try? c.decodeIfPresent(String.self, forKey: .step)
            detail = try? c.decodeIfPresent(String.self, forKey: .detail)
            done = try? c.decodeIfPresent(Int.self, forKey: .done)
            of = try? c.decodeIfPresent(Int.self, forKey: .of)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
            if let result = try? c.nestedContainer(keyedBy: ResultKeys.self, forKey: .result) {
                artifactId = try? result.decodeIfPresent(UUID.self, forKey: .artifactId)
            }
        }
    }

    let seq: Int
    let type: String
    let payload: Payload
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
    /// The request an offer of models was made for, so choosing one starts
    /// exactly that job instead of the router guessing what "Use Kling" means.
    var offerRequest: String? = nil
    var offerReferences: [String] = []
    /// What the questions on this turn were asked for, so the answers can go
    /// straight on to a strategy without the router reading them back.
    var questionRequest: String? = nil
    var questionDays: Int? = nil
    /// Long work handed to the worker on this turn. The card follows it live
    /// and becomes the result when it lands.
    var runId: UUID? = nil
    var runKind: String? = nil
    /// Something the agent made, drawn from the object rather than from prose.
    var artifactId: UUID? = nil
    /// Pictures the person attached, as paths in their own uploads folder.
    var attachments: [String] = []

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text)
    }

    static var thinking: ChatMessage {
        ChatMessage(role: .assistant, text: "", isPending: true)
    }
}
