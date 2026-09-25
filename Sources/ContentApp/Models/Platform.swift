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

    /// The network's own name, for account rows ("YouTube", not "Shorts").
    var networkName: String {
        switch self {
        case .tiktok: return "TikTok"
        case .reels:  return "Instagram"
        case .shorts: return "YouTube"
        }
    }

    /// The network's own mark, drawn in SwiftUI rather than shipped as its
    /// artwork -- see `BrandLogos.swift` for why.
    ///
    /// Abel, 25 Sep 2026: "instead of using TikTok, Instagram and YouTube, also
    /// put their real logo right there". The marks were drawn weeks ago and
    /// nothing ever used them; a monochrome music note stood in for TikTok on
    /// the one screen whose whole job is to be recognised at a glance.
    var logo: BrandLogo {
        switch self {
        case .tiktok: return .tiktok
        case .reels:  return .instagram
        case .shorts: return .youtube
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
