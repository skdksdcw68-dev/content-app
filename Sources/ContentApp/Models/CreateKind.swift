import Foundation

/// What a request to Create should come back as.
///
/// Deliberately short. The brief carries the interesting part -- what to make
/// it about -- so this only has to say what shape the result takes.
enum CreateKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case video
    case post
    case campaign

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .video:    return "Video"
        case .post:     return "Post"
        case .campaign: return "Campaign"
        }
    }

    var detail: String {
        switch self {
        case .video:    return "One short-form video, written and scheduled."
        case .post:     return "A still or carousel with a caption."
        case .campaign: return "A run of posts on one theme, spread over days."
        }
    }

    var symbolName: String {
        switch self {
        case .video:    return "video"
        case .post:     return "photo"
        case .campaign: return "square.stack"
        }
    }

    /// How many posts this adds to the queue. A campaign is the only one that
    /// is more than a single post.
    var postCount: Int {
        self == .campaign ? 4 : 1
    }
}

/// What the post is supposed to achieve.
///
/// Handed to the planner alongside the brief, and it changes the writing more
/// than the subject does -- the same idea written to be saved reads nothing
/// like the same idea written to be clicked.
enum CreateGoal: String, CaseIterable, Identifiable, Codable, Sendable {
    case reach
    case saves
    case clicks
    case teach

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reach:  return "Reach"
        case .saves:  return "Saves"
        case .clicks: return "Clicks"
        case .teach:  return "Teach"
        }
    }

    var detail: String {
        switch self {
        case .reach:  return "Written to be watched to the end by people who do not follow you."
        case .saves:  return "Written to be kept and come back to."
        case .clicks: return "Written to move people somewhere else."
        case .teach:  return "Written to leave one thing understood."
        }
    }

    var symbolName: String {
        switch self {
        case .reach:  return "antenna.radiowaves.left.and.right"
        case .saves:  return "bookmark"
        case .clicks: return "arrow.up.right"
        case .teach:  return "lightbulb"
        }
    }

    /// The same idea as `detail`, shaped to sit inside a sentence. Used in the
    /// rationale a requested post carries into the queue.
    var briefPhrase: String {
        switch self {
        case .reach:  return "to be watched to the end by people who do not follow you"
        case .saves:  return "to be kept and come back to"
        case .clicks: return "to move people somewhere else"
        case .teach:  return "to leave one thing understood"
        }
    }
}
