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
    var failed = false

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text)
    }

    static var thinking: ChatMessage {
        ChatMessage(role: .assistant, text: "", isPending: true)
    }
}
