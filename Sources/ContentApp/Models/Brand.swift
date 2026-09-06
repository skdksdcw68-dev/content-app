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

    enum CodingKeys: String, CodingKey {
        case id, name, audience, niche, timezone
        case usesMemory = "uses_memory"
    }

    /// Enough for the planner to write in a voice that is recognisably this
    /// account rather than a generic one.
    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !niche.trimmingCharacters(in: .whitespaces).isEmpty
            && !audience.trimmingCharacters(in: .whitespaces).isEmpty
    }
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
