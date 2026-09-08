import Foundation

/// A post as the app lists it: one row per destination account.
///
/// Mirrors `post_targets` joined to its `posts` parent, because everything that
/// differs per account -- the caption, the visibility, whether it has been
/// approved -- lives on the target, while the idea lives on the post.
struct PendingPost: Identifiable, Decodable, Hashable, Sendable {
    let id: UUID
    /// The idea this destination belongs to. Carried so a row in the plan can
    /// find the queue entry that came from it -- without it the two lists are
    /// the same posts with no way to say so.
    let postId: UUID
    let caption: String
    let state: State
    let privacy: String
    let isAIGC: Bool
    let consentId: UUID?
    let failureReason: String?
    /// When it actually went out. Needed by the week strip on Home, which has
    /// to know which day a post landed on rather than which day it was made.
    let publishedAt: Date?
    let post: Parent

    struct Parent: Decodable, Hashable, Sendable {
        let hook: String
        let status: PostStatus
        let createdAt: Date

        enum CodingKeys: String, CodingKey {
            case hook, status
            case createdAt = "created_at"
        }
    }

    enum State: String, Decodable, Sendable {
        case pending, claimed, uploading, submitted, processing
        case published, failed, cancelled
        case needsReapproval = "needs_reapproval"
    }

    enum CodingKeys: String, CodingKey {
        case id, caption, state, privacy
        case postId = "post_id"
        case isAIGC = "is_aigc"
        case consentId = "consent_id"
        case failureReason = "failure_reason"
        case publishedAt = "published_at"
        case post = "posts"
    }

    /// Approved, in the sense that a consent record exists for it.
    var isApproved: Bool { consentId != nil }

    /// Nothing more will happen to it without a person.
    var needsYou: Bool {
        state == .needsReapproval || (!isApproved && state == .pending)
    }

    var isBusy: Bool {
        state == .claimed || state == .uploading || state == .submitted || state == .processing
    }

    var statusLine: String {
        switch state {
        case .published:       return "Posted"
        case .failed:          return failureReason ?? "Failed"
        case .needsReapproval: return "Changed since you approved it"
        case .uploading:       return "Uploading to TikTok"
        case .submitted, .processing: return "TikTok is processing it"
        case .cancelled:       return "Cancelled"
        case .claimed:         return "Starting"
        case .pending:         return isApproved ? "Approved, ready to post" : "Waiting for you"
        }
    }
}

/// What TikTok says this account currently allows.
///
/// Fetched immediately before the approval sheet is shown, never cached. The
/// visibility options in particular are not ours to guess: an unaudited app
/// simply is not offered `PUBLIC_TO_EVERYONE`, and an account that has gone
/// private offers less again.
struct CreatorInfo: Decodable, Sendable {
    let snapshotId: UUID
    let username: String
    let nickname: String
    let avatarURL: URL?
    let privacyOptions: [String]
    let commentDisabled: Bool
    let duetDisabled: Bool
    let stitchDisabled: Bool
    let maxVideoSeconds: Int

    enum CodingKeys: String, CodingKey {
        case snapshotId = "snapshot_id"
        case username, nickname
        case avatarURL = "avatar_url"
        case privacyOptions = "privacy_level_options"
        case commentDisabled = "comment_disabled"
        case duetDisabled = "duet_disabled"
        case stitchDisabled = "stitch_disabled"
        case maxVideoSeconds = "max_video_seconds"
    }

    /// TikTok's enum values are not written for people.
    static func label(for privacy: String) -> String {
        switch privacy {
        case "PUBLIC_TO_EVERYONE":    return "Everyone"
        case "MUTUAL_FOLLOW_FRIENDS": return "Friends"
        case "FOLLOWER_OF_CREATOR":   return "Followers"
        case "SELF_ONLY":             return "Only me"
        default:                      return privacy
        }
    }

    static func detail(for privacy: String) -> String {
        switch privacy {
        case "PUBLIC_TO_EVERYONE":    return "Anyone on TikTok can see it."
        case "MUTUAL_FOLLOW_FRIENDS": return "People you follow who follow you back."
        case "FOLLOWER_OF_CREATOR":   return "Only people who follow you."
        case "SELF_ONLY":             return "Nobody else can see it."
        default:                      return ""
        }
    }
}
