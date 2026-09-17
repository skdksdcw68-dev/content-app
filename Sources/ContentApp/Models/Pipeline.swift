import SwiftUI

/// Where a post is in the loop, as `post_stage()` works it out from the rows
/// the pipeline writes. The app never decides this itself.
enum PipelineStage: String, Decodable, Hashable, Sendable, CaseIterable {
    case draft
    case readyForReview = "ready_for_review"
    case approved
    case scheduled
    case generating
    case readyToPublish = "ready_to_publish"
    case publishing
    case verifying
    case published
    case needsAttention = "needs_attention"

    init(from decoder: Decoder) throws {
        let raw = try String(from: decoder)
        self = PipelineStage(rawValue: raw) ?? .draft
    }

    var title: String {
        switch self {
        case .draft:          "Draft"
        case .readyForReview: "Ready for review"
        case .approved:       "Approved"
        case .scheduled:      "Scheduled"
        case .generating:     "Generating"
        case .readyToPublish: "Ready to publish"
        case .publishing:     "Publishing"
        case .verifying:      "Verifying"
        case .published:      "Published"
        case .needsAttention: "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .draft:          "doc.text"
        case .readyForReview: "eye"
        case .approved:       "checkmark.seal"
        case .scheduled:      "calendar"
        case .generating:     "sparkles"
        case .readyToPublish: "clock.badge.checkmark"
        case .publishing:     "arrow.up.circle"
        case .verifying:      "checkmark.circle.badge.questionmark"
        case .published:      "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .draft, .scheduled:              .secondary
        case .readyForReview:                 .orange
        case .approved, .readyToPublish:      .blue
        case .generating:                     .purple
        case .publishing, .verifying:         .indigo
        case .published:                      .green
        case .needsAttention:                 .red
        }
    }

    /// The person's move, not Autocast's.
    var isYourTurn: Bool { self == .readyForReview || self == .needsAttention }

    /// Autocast is doing something right now.
    var isWorking: Bool { self == .generating || self == .publishing || self == .verifying }
}

/// One post, everything about it: what will be published, where, when, and
/// how far it has got. From `post_board()`.
struct BoardPost: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let planId: UUID?
    let planTitle: String?
    let dayIndex: Int?
    let slotIndex: Int?
    let format: String?
    let hook: String
    let caption: String?
    let hashtags: [String]?
    let cta: String?
    let concept: String?
    let rationale: String?
    let pillar: String?
    let status: String
    let mediaStrategy: String?
    let scheduledFor: String?
    let platform: String?
    let username: String?
    let connectionStatus: String?
    let targetId: UUID?
    let targetState: String?
    let privacy: String?
    let approved: Bool
    let publishedAt: String?
    let providerPostId: String?
    let jobState: String?
    let attempts: Int?
    let problem: String?
    let media: Media?
    let generation: String?
    let stage: PipelineStage
    let activity: [ActivityEvent]?

    struct Media: Decodable, Hashable, Sendable {
        let bucket: String?
        let path: String
        let mime: String?
        let bytes: Int?
        let source: String?
    }

    var when: Date? { scheduledFor.flatMap(PostgresTimestamp.parse) }
    var publishedDate: Date? { publishedAt.flatMap(PostgresTimestamp.parse) }
    var isPrepared: Bool { targetId != nil }

    /// Exactly what goes out: once prepared, the target's caption (which
    /// already carries the CTA) plus hashtags; before that, the plan's words.
    var publishText: String {
        let body: String
        if isPrepared {
            body = caption ?? ""
        } else {
            body = [caption ?? "", cta ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return ([body] + (hashtags ?? [])).filter { !$0.isEmpty }.joined(separator: " ")
    }

    var platformName: String {
        switch platform {
        case "reels":  "Instagram"
        case "shorts": "YouTube"
        default:       "TikTok"
        }
    }

    var privacyName: String? {
        guard let privacy else { return nil }
        return CreatorInfo.label(for: privacy)
    }

    var tiktokURL: URL? {
        guard let providerPostId, let username else { return nil }
        return URL(string: "https://www.tiktok.com/@\(username)/video/\(providerPostId)")
    }
}

/// Something Autocast, you, or the platform did. Written by the database
/// whenever the rows actually change.
struct ActivityEvent: Decodable, Identifiable, Hashable, Sendable {
    let kind: String
    let actor: String
    let title: String
    let detail: String
    let at: String
    var postId: UUID? = nil
    var hook: String? = nil

    var id: String { "\(at)|\(kind)|\(postId?.uuidString ?? "")" }
    var date: Date? { PostgresTimestamp.parse(at) }

    /// The "Scheduled" and "New time set" rows carry the time as ISO text.
    var detailDate: Date? {
        guard kind == "scheduled" || kind == "rescheduled" else { return nil }
        return PostgresTimestamp.parse(detail)
    }

    var isYou: Bool { actor == "you" }

    var symbol: String {
        switch kind {
        case "understood":          "eye"
        case "prepared":            "shippingbox"
        case "validated":           "checkmark.shield"
        case "validation_failed":   "exclamationmark.shield"
        case "approved":            "hand.thumbsup"
        case "scheduled", "rescheduled": "calendar.badge.clock"
        case "publishing":          "arrow.up.circle"
        case "verifying":           "hourglass"
        case "published":           "checkmark.circle.fill"
        case "failed":              "exclamationmark.triangle.fill"
        case "held", "needs_reapproval": "pause.circle"
        case "generating":          "sparkles"
        case "generated":           "film"
        case "paused":              "pause.fill"
        case "resumed":             "play.fill"
        case "plan":                "calendar"
        default:                    "circle"
        }
    }

    var tint: Color {
        switch kind {
        case "published":                       .green
        case "failed", "validation_failed":     .red
        case "held", "needs_reapproval", "paused": .orange
        default:                                .secondary
        }
    }
}

/// The machine, for one brand. From `autopilot_overview()`.
struct AutopilotOverview: Decodable, Sendable {
    let brand: BrandRef
    let publishingOn: Bool
    let aiVideosOn: Bool
    let requiresApproval: Bool
    let connection: Connection?
    let plan: Plan?
    let nextAction: String
    let nextPost: PostRef?
    let lastPublished: PostRef?
    let counts: Counts
    let activity: [ActivityEvent]

    struct BrandRef: Decodable, Sendable {
        let id: UUID
        let name: String
        let timezone: String
    }

    struct Connection: Decodable, Sendable {
        let platform: String
        let username: String
        let status: String
    }

    struct Plan: Decodable, Sendable {
        let id: UUID
        let title: String
        let objective: String?
        let startsOn: String
        let days: Int
        let postsPerDay: Int
    }

    struct PostRef: Decodable, Sendable {
        let id: UUID
        let hook: String
        let at: String?
        let privacy: String?
        let providerPostId: String?

        var date: Date? { at.flatMap(PostgresTimestamp.parse) }
    }

    struct Counts: Decodable, Sendable {
        let published: Int
        let publishedInPlan: Int
        let inPlan: Int
        let queued: Int
        let waitingForYou: Int
        let needsAttention: Int
        let inFlight: Int
    }

    enum Move {
        case yours(String)
        case autocasts(String)
    }

    /// One sentence about what happens next, and whose move it is.
    var next: Move {
        switch nextAction {
        case "connect":      .yours("Connect TikTok so Autocast can publish for \(brand.name).")
        case "reconnect":    .yours("TikTok needs you to sign in again.")
        case "paused":       .yours("Autopilot is paused. Nothing is published until you resume.")
        case "fix":          .yours("\(counts.needsAttention) post\(counts.needsAttention == 1 ? "" : "s") need\(counts.needsAttention == 1 ? "s" : "") your attention.")
        case "review":       .yours("\(counts.waitingForYou) post\(counts.waitingForYou == 1 ? " is" : "s are") ready for your review.")
        case "publish_next": .autocasts("Publishing the next post at its time.")
        case "plan":         .yours("Plan content or upload a video to get started.")
        default:             .yours("Add content to the plan — upload a video or plan more posts.")
        }
    }
}

/// What `content-item` wrote for an uploaded video.
struct UnderstoodVideo: Decodable, Sendable {
    let postId: UUID
    let planId: UUID
    let planTitle: String
    let hook: String
    let caption: String
    let cta: String
    let hashtags: [String]
    let concept: String
    let scheduledFor: String?
}

struct PreparedItem: Decodable, Sendable {
    let ok: Bool
    let reason: String?
    let username: String?
}

struct ValidationReport: Decodable, Sendable {
    let ok: Bool
    let checks: [Check]
    let privacyOptions: [String]
    let username: String?

    struct Check: Decodable, Identifiable, Hashable, Sendable {
        let key: String
        let title: String
        let ok: Bool
        let detail: String
        var id: String { key }
    }
}
