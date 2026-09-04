import Foundation

/// A place Autocast can publish to.
///
/// Raw values are the strings the backend stores, so renaming a case is a
/// migration, not a refactor.
enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    case tiktok
    case reels
    case shorts

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiktok: return "TikTok"
        case .reels:  return "Reels"
        case .shorts: return "Shorts"
        }
    }

    /// SF Symbol used on badges and the connect rows.
    var symbolName: String {
        switch self {
        case .tiktok: return "music.note"
        case .reels:  return "play.square.stack"
        case .shorts: return "play.rectangle.on.rectangle"
        }
    }

    /// Hard ceiling the platform enforces on a short. Autocast never plans a
    /// script whose estimated read-time exceeds this.
    var maxDuration: TimeInterval {
        switch self {
        case .tiktok: return 180
        case .reels:  return 90
        case .shorts: return 60
        }
    }
}
