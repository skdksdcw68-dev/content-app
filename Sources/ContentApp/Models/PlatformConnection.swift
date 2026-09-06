import Foundation

/// A linked social account, as the app is allowed to see it.
///
/// Note what is absent: there is no token here, and there is no way to ask for
/// one. The access and refresh tokens live encrypted in a schema PostgREST does
/// not expose, and only the publisher, over a direct database connection, can
/// decrypt them. The phone gets a name, a face, and whether it is working.
struct PlatformConnection: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let brandId: UUID
    let platform: Platform
    /// The account's own handle, from `user.info.profile`.
    let username: String
    let displayName: String
    let avatarURL: URL?
    let scopes: [String]
    let status: Status
    let connectedAt: Date
    let lastError: String?

    enum Status: String, Codable, Sendable {
        case active, expired, revoked, error
    }

    enum CodingKeys: String, CodingKey {
        case id
        case brandId = "brand_id"
        case platform, username, scopes, status
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case connectedAt = "connected_at"
        case lastError = "last_error"
    }

    var isHealthy: Bool { status == .active }

    /// What to put on screen next to the avatar.
    ///
    /// TikTok requires the creator be identifiable before every post, and
    /// display names are frequently blank, whitespace, or a single invisible
    /// character -- so the handle is what is shown, and the display name is
    /// only ever decoration.
    var label: String { "@\(username)" }

    /// A short reason the connection is not usable, when it is not.
    var problem: String? {
        switch status {
        case .active:  return nil
        case .expired: return "The connection expired. Reconnect to keep posting."
        case .revoked: return "Access was revoked on \(platform.displayName)."
        case .error:   return lastError ?? "Something is wrong with this connection."
        }
    }
}
