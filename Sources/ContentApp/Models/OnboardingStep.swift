import Foundation

/// One onboarding question, as data.
///
/// Same shape as email-app's: questions are rows in an array, not hand-written
/// screens, so there is one question view to maintain and reordering the set
/// never touches SwiftUI.
struct OnboardingQuestion: Identifiable, Hashable, Sendable {
    enum Selection: Sendable { case single, multiple }

    struct Option: Identifiable, Hashable, Sendable {
        let id: String
        let label: String
        /// An SF Symbol, not an emoji. Emoji are somebody else's artwork at a
        /// fixed weight: they ignore Dynamic Type, tint, and Dark Mode.
        let symbol: String
        /// The longer line, where an option needs one. Only the voice question
        /// uses it, which is why the layout adapts rather than being declared.
        var detail: String?
    }

    let id: String
    let title: String
    let subtitle: String
    let selection: Selection
    let options: [Option]

    /// Options with a description read as rows; bare labels read as a wrapping
    /// field of chips. Derived rather than configured, so the two can never
    /// disagree.
    var isDetailed: Bool { options.contains { $0.detail != nil } }
}

// MARK: - The questions

extension OnboardingQuestion {
    static let all: [OnboardingQuestion] = [product, audience, voice]

    /// Writes `brands.niche`. The reference calls this "What did you build?"
    /// and offers thirty-five categories; the planner needs a sentence, not a
    /// taxonomy, so the categories are a way of writing one quickly rather
    /// than a field of their own.
    static let product = OnboardingQuestion(
        id: "product",
        title: "What did you build?",
        subtitle: "So it writes about your thing rather than in general.",
        selection: .single,
        options: [
            .init(id: "app", label: "An app", symbol: "iphone"),
            .init(id: "saas", label: "Software people pay for", symbol: "square.stack.3d.up"),
            .init(id: "shop", label: "A shop", symbol: "bag"),
            .init(id: "service", label: "A service", symbol: "hands.and.sparkles"),
            .init(id: "course", label: "A course or book", symbol: "book"),
            .init(id: "newsletter", label: "A newsletter", symbol: "envelope"),
            .init(id: "community", label: "A community", symbol: "person.3"),
            .init(id: "agency", label: "An agency", symbol: "briefcase"),
            .init(id: "creator", label: "Myself, as a creator", symbol: "person.wave.2"),
            .init(id: "game", label: "A game", symbol: "gamecontroller"),
            .init(id: "tool", label: "A tool for developers", symbol: "hammer"),
            .init(id: "other", label: "Something else", symbol: "sparkles"),
        ]
    )

    /// Writes `brands.audience`.
    static let audience = OnboardingQuestion(
        id: "audience",
        title: "Who is it for?",
        subtitle: "Pick as many as fit. It writes to these people.",
        selection: .multiple,
        options: [
            .init(id: "founders", label: "Founders", symbol: "lightbulb"),
            .init(id: "developers", label: "Developers", symbol: "chevron.left.forwardslash.chevron.right"),
            .init(id: "designers", label: "Designers", symbol: "paintbrush"),
            .init(id: "marketers", label: "Marketers", symbol: "megaphone"),
            .init(id: "creators", label: "Creators", symbol: "camera"),
            .init(id: "students", label: "Students", symbol: "graduationcap"),
            .init(id: "freelancers", label: "Freelancers", symbol: "laptopcomputer"),
            .init(id: "small_business", label: "Small businesses", symbol: "storefront"),
            .init(id: "teams", label: "Teams at work", symbol: "person.2"),
            .init(id: "parents", label: "Parents", symbol: "figure.and.child.holdinghands"),
            .init(id: "gamers", label: "Gamers", symbol: "gamecontroller"),
            .init(id: "anyone", label: "Anyone, really", symbol: "globe"),
        ]
    )

    /// Writes `brand_settings.tone`, which the planner reads.
    static let voice = OnboardingQuestion(
        id: "voice",
        title: "What's your voice?",
        subtitle: "How it should sound when it writes for you.",
        selection: .single,
        options: [
            .init(
                id: "plain",
                label: "Plain and direct",
                symbol: "text.alignleft",
                detail: "Short sentences. Says the thing. No wind-up."
            ),
            .init(
                id: "warm",
                label: "Warm and personal",
                symbol: "heart",
                detail: "Writes like a person talking to one other person."
            ),
            .init(
                id: "dry",
                label: "Dry and funny",
                symbol: "face.smiling",
                detail: "Understated. Never tries too hard for the joke."
            ),
            .init(
                id: "expert",
                label: "Expert and specific",
                symbol: "chart.bar.doc.horizontal",
                detail: "Leads with the detail. Assumes the reader is clever."
            ),
        ]
    )
}

// MARK: - The flow

/// Where somebody is in first-run.
///
/// Persisted by raw value, so closing the app mid-flow comes back to the same
/// step rather than starting over -- and rather than skipping setup entirely,
/// which is what "finished unless proven otherwise" would do.
enum OnboardingStep: Equatable, Hashable, Sendable {
    case welcome
    case question(Int)
    case connectAccount
    case connectGenerator
    case done

    var storedValue: String {
        switch self {
        case .welcome:          return "welcome"
        case .question(let i):  return "question:\(i)"
        case .connectAccount:   return "account"
        case .connectGenerator: return "generator"
        case .done:             return "done"
        }
    }

    init?(stored: String) {
        switch stored {
        case "welcome":   self = .welcome
        case "account":   self = .connectAccount
        case "generator": self = .connectGenerator
        case "done":      self = .done
        default:
            guard stored.hasPrefix("question:"),
                  let index = Int(stored.dropFirst("question:".count))
            else { return nil }
            self = .question(index)
        }
    }

    /// How far along, for the bar at the top. Welcome has none -- a progress
    /// bar on the first screen tells somebody how long this will take before
    /// they have agreed to take it.
    var progress: Double? {
        let total = Double(OnboardingQuestion.all.count + 2)
        switch self {
        case .welcome:          return nil
        case .question(let i):  return Double(i + 1) / total
        case .connectAccount:   return Double(OnboardingQuestion.all.count + 1) / total
        case .connectGenerator: return 1
        case .done:             return 1
        }
    }
}
