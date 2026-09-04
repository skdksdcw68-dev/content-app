import Foundation

/// A publishing destination the person has linked.
///
/// The autopilot will not plan for a platform with no connected account -- an
/// unposted queue is worse than an empty one.
struct SocialAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var platform: Platform
    var handle: String
    var connectedAt: Date
    /// Set when the token expires or is revoked. A disconnected account keeps
    /// its row so history stays readable.
    var disconnectedAt: Date?

    init(
        id: UUID = UUID(),
        platform: Platform,
        handle: String,
        connectedAt: Date = Date(),
        disconnectedAt: Date? = nil
    ) {
        self.id = id
        self.platform = platform
        self.handle = handle
        self.connectedAt = connectedAt
        self.disconnectedAt = disconnectedAt
    }

    var isConnected: Bool { disconnectedAt == nil }
}
