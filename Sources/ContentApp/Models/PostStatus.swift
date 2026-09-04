import Foundation

/// Where a post sits in the autopilot pipeline.
///
/// The order of the cases IS the pipeline order, and `pipelineRank` depends on
/// it -- keep them in sequence.
enum PostStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The autopilot picked the idea but has not written it yet.
    case planned
    /// Hook, script and caption are written; nothing has been rendered.
    case scripted
    /// A render job is in flight.
    case rendering
    /// Rendered and waiting for its slot. This is where a post sits when
    /// `AutopilotSettings.requiresApproval` is on and nobody has approved it.
    case scheduled
    /// Published. `ContentPost.postedAt` is set.
    case posted
    /// Something went wrong. `ContentPost.failureReason` says what.
    case failed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .planned:   return "Planned"
        case .scripted:  return "Scripted"
        case .rendering: return "Rendering"
        case .scheduled: return "Scheduled"
        case .posted:    return "Posted"
        case .failed:    return "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .planned:   return "lightbulb"
        case .scripted:  return "text.alignleft"
        case .rendering: return "wand.and.stars"
        case .scheduled: return "clock"
        case .posted:    return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        }
    }

    var pipelineRank: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// True once the autopilot can no longer change the post on its own.
    var isTerminal: Bool { self == .posted || self == .failed }

    /// Statuses that still represent work the autopilot owes you.
    static var upcoming: [PostStatus] { [.planned, .scripted, .rendering, .scheduled] }
}
