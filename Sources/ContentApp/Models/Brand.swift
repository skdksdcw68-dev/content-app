import Foundation

/// An account the agent works for.
///
/// Mirrors the `brands` row. A person can have more than one -- their app, their
/// consultancy -- and they share nothing: not the voice, not the schedule, not
/// the connected accounts.
struct Brand: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var audience: String
    var niche: String
    /// IANA zone. Every scheduling decision is made in this, never in UTC and
    /// never in whatever the phone happens to be set to.
    var timezone: String
    var usesMemory: Bool
    /// The Brand page's questionnaire, keyed by question id. Nil on rows read
    /// with a column list that leaves it out.
    var profile: [String: BrandAnswer]?
    /// Where the brand mark lives in the `brand` bucket, or nil when there is
    /// none. A path, never a URL: a signed link expires, and one written into a
    /// row is a link that cannot resolve later or on another device.
    var logoPath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, audience, niche, timezone, profile
        case usesMemory = "uses_memory"
        case logoPath = "logo_path"
    }

    /// Enough for the planner to write in a voice that is recognisably this
    /// account rather than a generic one.
    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !niche.trimmingCharacters(in: .whitespaces).isEmpty
            && !audience.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether this brand went through the questions. A server fact, not a
    /// flag on the phone: the flag let somebody tap Log in, create an account
    /// with Apple, and land in the app having answered nothing (Abel,
    /// 23 Sep 2026: "there should be no way to bypass the onboarding").
    var answeredOnboarding: Bool {
        let ids = OnboardingQuestion.all.map(\.id)
        guard !ids.isEmpty else { return true }
        let answered = ids.filter { profile?[$0] != nil }.count
        return answered >= max(1, ids.count / 2)
    }
}

/// One answered question, stored with its title and the chosen labels so the
/// writers on the server can print it without a copy of the question set.
struct BrandAnswer: Codable, Hashable, Sendable {
    var title: String
    var answers: [String]
}

/// What the app sends when creating one. Separate from `Brand` because the id
/// and the timestamps are the database's to decide.
struct NewBrand: Encodable, Sendable {
    let userId: UUID
    let name: String
    let timezone: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name, timezone
    }
}
