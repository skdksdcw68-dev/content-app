import Foundation

/// A month of content, before anyone has agreed to it.
///
/// Mirrors `content_plans`. The distinction that matters is `status`: a plan is
/// `proposed` until a person calls `activate_plan`, and a proposed plan is a
/// document -- it schedules nothing, spends nothing, and costs one tap to throw
/// away. Everything the agent decides lands here first.
struct ContentPlan: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    let title: String
    let status: Status
    /// A Postgres `date`, kept as the string it arrives as. Parsing it into a
    /// `Date` would attach a time and a zone that the value does not have, and
    /// the only thing this is used for is a label.
    let startsOn: String
    let days: Int
    let postsPerDay: Int
    let brief: String
    let approvedAt: Date?

    enum Status: String, Decodable, Sendable {
        case draft, proposed, approved, active, paused, archived
    }

    enum CodingKeys: String, CodingKey {
        case id, title, status, days, brief
        case startsOn = "starts_on"
        case postsPerDay = "posts_per_day"
        case approvedAt = "approved_at"
    }

    /// Waiting on a person: written, costed, and doing nothing yet.
    var isProposal: Bool { status == .draft || status == .proposed }

    var isRunning: Bool { status == .active }
}

/// One post inside a plan.
///
/// Mirrors `posts` joined to its theme. This is the row before it has media, a
/// destination account or consent -- the idea and the time, and nothing else.
struct PlannedPost: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    let dayIndex: Int?
    let slotIndex: Int
    let hook: String
    /// The caption. Called `script` in the schema because the column outlived
    /// the meaning; renaming it is a migration for no gain.
    let script: String
    /// What the video should show, written as an instruction. This is what the
    /// media step will be handed when there is one.
    let concept: String
    let rationale: String
    let status: PostStatus
    let scheduledFor: Date?
    let pillar: Pillar?

    struct Pillar: Decodable, Hashable, Sendable {
        let name: String
    }

    enum CodingKeys: String, CodingKey {
        case id, hook, script, concept, rationale, status
        case dayIndex = "day_index"
        case slotIndex = "slot_index"
        case scheduledFor = "scheduled_for"
        case pillar = "content_pillars"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        dayIndex = try container.decodeIfPresent(Int.self, forKey: .dayIndex)
        slotIndex = try container.decodeIfPresent(Int.self, forKey: .slotIndex) ?? 0
        hook = try container.decodeIfPresent(String.self, forKey: .hook) ?? ""
        script = try container.decodeIfPresent(String.self, forKey: .script) ?? ""
        concept = try container.decodeIfPresent(String.self, forKey: .concept) ?? ""
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        status = try container.decodeIfPresent(PostStatus.self, forKey: .status) ?? .planned
        pillar = try container.decodeIfPresent(Pillar.self, forKey: .pillar)

        // Decoded by hand because PostgREST drops the fractional seconds when a
        // timestamp has none. `created_at` always has them and parses with the
        // stock decoder; `scheduled_for` lands exactly on the hour and does not,
        // so a single ISO8601 formatter silently returns nil for every slot.
        let raw = try container.decodeIfPresent(String.self, forKey: .scheduledFor)
        scheduledFor = raw.flatMap(PostgresTimestamp.parse)
    }
}

/// Parses the two shapes PostgREST actually emits for a `timestamptz`.
enum PostgresTimestamp {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        withFraction.date(from: value) ?? plain.date(from: value)
    }
}

/// What `propose-plan` reports back.
///
/// `planned` and `slots` are separate on purpose. Asking for thirty days when
/// today's slot has already passed gives twenty-nine slots, and a model that
/// skips one gives twenty-eight posts. Both numbers are shown rather than
/// quietly rounded to what was asked for.
struct PlanProposal: Decodable, Sendable {
    let planId: UUID
    let title: String
    let startsOn: String
    let days: Int
    let postsPerDay: Int
    let planned: Int
    let dropped: Int
    let slots: Int

    enum CodingKeys: String, CodingKey {
        case title, days, planned, dropped, slots
        case planId = "plan_id"
        case startsOn = "starts_on"
        case postsPerDay = "posts_per_day"
    }
}
