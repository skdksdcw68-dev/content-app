import Foundation

/// Where a post sits in the pipeline.
///
/// The raw values are the Postgres enum in migration 0002, and the declaration
/// order is the pipeline order -- `pipelineRank` depends on it, and so does the
/// database. Two stages are new since the queue-shaped first version:
/// `sourcing`, while the media is being made, and `needsApproval`, when media
/// exists that nobody has looked at yet.
enum PostStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case planned
    case scripted
    case sourcing
    case needsApproval = "needs_approval"
    case scheduled
    case posted
    case failed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .planned:       return "Planned"
        case .scripted:      return "Scripted"
        case .sourcing:      return "Making"
        case .needsApproval: return "Needs you"
        case .scheduled:     return "Scheduled"
        case .posted:        return "Posted"
        case .failed:        return "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .planned:       return "lightbulb"
        case .scripted:      return "text.alignleft"
        case .sourcing:      return "wand.and.stars"
        case .needsApproval: return "hand.raised"
        case .scheduled:     return "clock"
        case .posted:        return "checkmark.circle.fill"
        case .failed:        return "exclamationmark.triangle.fill"
        }
    }

    var pipelineRank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// True once nothing further will happen to it on its own.
    var isTerminal: Bool { self == .posted || self == .failed }

    /// The one stage that is waiting on a person rather than on the system.
    var isWaitingOnYou: Bool { self == .needsApproval }
}
