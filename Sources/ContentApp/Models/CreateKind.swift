import Foundation

/// The things a person can ask for directly, from the Create button.
///
/// The autopilot plans on its own; these exist for the times you want
/// something specific and do not want to wait for it to be chosen for you.
/// Every one of them still produces a `.planned` post that moves through the
/// same pipeline -- asking is a shortcut into the queue, not a way around it.
enum CreateKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case video
    case post
    case campaign
    case askAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video:    return "Video"
        case .post:     return "Image / Post"
        case .campaign: return "Campaign"
        case .askAI:    return "Ask AI"
        }
    }

    var detail: String {
        switch self {
        case .video:    return "One short-form video, written and scheduled."
        case .post:     return "A still or carousel with a caption."
        case .campaign: return "A run of posts on one theme, spread over days."
        case .askAI:    return "Describe what you want and let it work out the rest."
        }
    }

    var symbolName: String {
        switch self {
        case .video:    return "video"
        case .post:     return "photo"
        case .campaign: return "calendar.badge.plus"
        case .askAI:    return "sparkles"
        }
    }

    /// How many posts asking for this adds to the queue. A campaign is the
    /// only one that is more than a single post.
    var postCount: Int {
        self == .campaign ? 4 : 1
    }
}
