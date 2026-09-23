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
    /// The Brand page's questions, the ones worth asking on day one. Each
    /// answer lands in brands.profile exactly as the Brand page saves it, so
    /// the two never disagree (Abel, 19 Sep 2026: "selections and questions,
    /// like onboarding").
    static var all: [OnboardingQuestion] {
        // Twelve now, not six: a series needs the rhythm, the platforms,
        // the length, whether they are on camera and what to leave out
        // before it can plan a month (Abel, 23 Sep 2026). Anyone who
        // answered the original six still counts as done -- see
        // `Brand.answeredOnboarding`, which asks for half.
        [BrandQuestions.category, BrandQuestions.goal, BrandQuestions.audience,
         BrandQuestions.platforms, BrandQuestions.styles, BrandQuestions.formats,
         BrandQuestions.length, BrandQuestions.cadence, BrandQuestions.camera,
         BrandQuestions.voice, BrandQuestions.cta, BrandQuestions.avoid]
    }

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
    /// Signing up, or coming back to an account that already exists.
    enum Mode: String, Equatable, Hashable, Sendable { case signup, login }

    /// How somebody arrived, which is all that Verified says differently.
    enum Arrival: String, Equatable, Hashable, Sendable {
        /// A new account was made.
        case created
        /// That address already had one, so their account was loaded.
        case alreadyRegistered
        /// They logged in on purpose.
        case returning
    }

    case welcome
    case question(Int)
    /// The ring, while the answers are written to the brand.
    case building
    /// What Autocast does, before anybody is asked for anything.
    case included
    /// Apple, Google, email -- or Continue as Guest.
    case account
    case email(Mode)
    case code(Mode)
    case verified(Arrival)
    case done

    var storedValue: String {
        switch self {
        case .welcome:            return "welcome"
        case .question(let i):    return "question:\(i)"
        case .building:           return "building"
        case .included:           return "included"
        case .account:            return "account"
        case .email(let mode):    return "email:\(mode.rawValue)"
        case .code(let mode):     return "code:\(mode.rawValue)"
        case .verified(let how):  return "verified:\(how.rawValue)"
        case .done:               return "done"
        }
    }

    init?(stored: String) {
        switch stored {
        case "welcome":   self = .welcome
        case "building":  self = .building
        case "included":  self = .included
        case "account":   self = .account
        case "done":      self = .done
        // Steps that no longer exist. "name" asked for a name before anybody
        // had used anything, which App Review rejects; "generator" was the old
        // connect-a-generator screen.
        case "name":      self = .welcome
        case "generator": self = .done
        default:
            if stored.hasPrefix("question:"), let index = Int(stored.dropFirst("question:".count)) {
                self = .question(index)
            } else if stored.hasPrefix("email:"), let mode = Mode(rawValue: String(stored.dropFirst(6))) {
                self = .email(mode)
            } else if stored.hasPrefix("code:"), let mode = Mode(rawValue: String(stored.dropFirst(5))) {
                self = .code(mode)
            } else if stored.hasPrefix("verified:"), let how = Arrival(rawValue: String(stored.dropFirst(9))) {
                self = .verified(how)
            } else {
                return nil
            }
        }
    }

    /// True where the back chevron belongs: everywhere somebody chose to go,
    /// and nowhere they were sent (Remi's `canGoBack`).
    var canGoBack: Bool {
        switch self {
        case .question, .included, .account, .email, .code: return true
        case .welcome, .building, .verified, .done: return false
        }
    }

    /// How far along, for the bar at the top. Welcome has none -- a progress
    /// bar on the first screen tells somebody how long this will take before
    /// they have agreed to take it.
    /// 🔴 The bar used to reach 100% on the generator screen — the last screen
    /// somebody still has to act on. It told them they had finished while they
    /// were still working, which is the one thing a progress bar must never
    /// do: the last step looked like no step at all, and pressing the button
    /// under a full bar feels like being tricked.
    ///
    /// The denominator counts the steps *plus the end*, so every screen is a
    /// fraction of the way there and only `done` is full. Five screens now
    /// read 17, 33, 50, 67, 83 — and the bar still has somewhere to go when
    /// the last one is on screen, which is what makes it worth having.
    /// Only the part somebody is answering carries a bar: the welcome screen
    /// has none, and neither do the account screens, which are a choice rather
    /// than a queue to be got through.
    var progress: Double? {
        switch self {
        case .question(let i):  return Double(i + 1) / Double(OnboardingQuestion.all.count)
        case .done:             return 1
        // The ring and everything after it are not a queue being got through,
        // so they carry no bar at all.
        case .welcome, .building, .included, .account, .email, .code, .verified: return nil
        }
    }
}
