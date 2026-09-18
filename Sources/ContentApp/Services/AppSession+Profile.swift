import Foundation
import Supabase
import CryptoKit
import AuthenticationServices

/// The Profile page's side of the session: the account itself (Apple, sign
/// out, delete), a platform account's disconnect, pillars, usage, activity,
/// and exporting everything. Each reads or writes real rows; nothing here
/// keeps a number of its own.
extension AppSession {
    // MARK: - Sign in with Apple

    /// A fresh random nonce, and its SHA-256 for Apple's request. Apple signs
    /// the hash into the ID token; Supabase checks the raw one against it, so
    /// a token lifted from somewhere else cannot be replayed here.
    static func appleNonce() -> (raw: String, hashed: String) {
        let raw = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let hashed = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return (raw, hashed)
    }

    enum AppleOutcome {
        /// This anonymous account is now the Apple account. Nothing moved.
        case linked
        /// That Apple ID already had an account; the app is now that one.
        case switched
        case failed
    }

    /// Makes this account permanent with the Apple ID just approved.
    ///
    /// Linking first, so the same user id keeps every brand, plan and video.
    /// If the Apple ID already belongs to an account -- signing back in after
    /// signing out, or a second phone -- linking is refused, and the right
    /// move is to become that account instead.
    func signInWithApple(_ authorization: ASAuthorization, nonce: String) async -> AppleOutcome {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            lastError = "Apple didn’t send a sign-in token. Try again."
            return .failed
        }
        let credentials = OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)

        do {
            if isAnonymous {
                do {
                    let linked = try await client.auth.linkIdentityWithIdToken(credentials: credentials)
                    readAccount(linked.user)
                    return .linked
                } catch {
                    // Already someone's account: fall through to signing in as it.
                    let text = "\(error)".lowercased()
                    guard text.contains("already") || text.contains("identity_exists") || text.contains("exists") else {
                        throw error
                    }
                }
            }
            _ = try await client.auth.signInWithIdToken(credentials: credentials)
            await restart()
            return .switched
        } catch {
            lastError = readableMessage(error)
            return .failed
        }
    }

    /// Signs out, then opens again as a new empty anonymous account. The Apple
    /// account and everything in it is still there to sign back in to.
    func signOut() async {
        try? await client.auth.signOut()
        await restart()
    }

    /// Everything, for real: the server revokes TikTok, deletes the files and
    /// the user, and every row cascades with it.
    @discardableResult
    func deleteAccount() async -> Bool {
        struct Result: Decodable, Sendable { let deleted: Bool }
        do {
            let result: Result = try await client.functions.invoke(
                "delete-account",
                options: FunctionInvokeOptions(body: ["confirm": "DELETE"])
            )
            guard result.deleted else { return false }
            try? await client.auth.signOut(scope: .local)
            await restart()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    // MARK: - A platform account

    /// Revokes at TikTok and forgets it here. Anything queued for the account
    /// is cancelled by the database in the same step.
    @discardableResult
    func disconnectAccount(_ connection: PlatformConnection) async -> Bool {
        do {
            try await client.functions.invoke(
                "tiktok-disconnect",
                options: FunctionInvokeOptions(body: ["connection_id": connection.id.uuidString])
            )
            await refreshConnections()
            await refreshHealth()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    // MARK: - Pillars

    func pillars() async -> [ContentPillar] {
        guard let brand else { return [] }
        do {
            return try await client
                .from("content_pillars")
                .select("id,name,detail,weight,is_enabled")
                .eq("brand_id", value: brand.id.uuidString)
                .order("created_at", ascending: true)
                .execute()
                .value
        } catch {
            lastError = readableMessage(error)
            return []
        }
    }

    @discardableResult
    func savePillar(_ pillar: ContentPillar) async -> Bool {
        guard let brand, let userID else { return false }
        struct Row: Encodable, Sendable {
            let id: UUID
            let user_id: UUID
            let brand_id: UUID
            let name: String
            let detail: String
            let weight: Int
            let is_enabled: Bool
        }
        do {
            try await client
                .from("content_pillars")
                .upsert(Row(
                    id: pillar.id, user_id: userID, brand_id: brand.id,
                    name: pillar.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    detail: pillar.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                    weight: max(1, pillar.weight), is_enabled: pillar.isEnabled
                ))
                .execute()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    @discardableResult
    func deletePillar(_ id: UUID) async -> Bool {
        do {
            try await client.from("content_pillars").delete().eq("id", value: id.uuidString).execute()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    // MARK: - Usage and activity

    func usage(since start: Date) async -> UsageSummary? {
        guard let brand else { return nil }
        struct Params: Encodable, Sendable {
            let p_brand: String
            let p_from: String
        }
        do {
            let response = try await client
                .rpc("usage_summary", params: Params(
                    p_brand: brand.id.uuidString,
                    p_from: ISO8601DateFormatter().string(from: start)
                ))
                .execute()
            // A plain decoder: snake-case conversion would also rename the
            // keys inside by_kind ("plan_write" -> "planWrite").
            return try JSONDecoder().decode(UsageSummary.self, from: response.data)
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }

    /// Everything that happened for this brand, newest first.
    func activityHistory(limit: Int = 300) async -> [ActivityEvent] {
        guard let brand else { return [] }
        struct Row: Decodable, Sendable {
            let kind: String
            let actor: String
            let title: String
            let detail: String?
            let at: String
            let post_id: UUID?
            let posts: PostHook?
            struct PostHook: Decodable, Sendable { let hook: String? }
        }
        do {
            let rows: [Row] = try await client
                .from("activity_events")
                .select("kind,actor,title,detail,at,post_id,posts(hook)")
                .eq("brand_id", value: brand.id.uuidString)
                .order("at", ascending: false)
                .limit(limit)
                .execute()
                .value
            return rows.map {
                ActivityEvent(kind: $0.kind, actor: $0.actor, title: $0.title, detail: $0.detail ?? "",
                              at: $0.at, postId: $0.post_id, hook: $0.posts?.hook)
            }
        } catch {
            lastError = readableMessage(error)
            return []
        }
    }

    // MARK: - Export

    struct DataExport: Decodable, Sendable {
        let url: URL
        let filename: String
        let size: Int
    }

    /// Builds the ZIP on the server and downloads it, so the share sheet has
    /// a real file to hand on rather than a link that expires in an hour.
    func exportData() async -> URL? {
        do {
            let made: DataExport = try await client.functions.invoke("export-data", options: FunctionInvokeOptions(body: [String: String]()))
            let (downloaded, _) = try await URLSession.shared.download(from: made.url)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(made.filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloaded, to: destination)
            return destination
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }
}

// MARK: - Models

/// A theme the planner builds a month from. Mirrors `content_pillars`.
struct ContentPillar: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var detail: String
    var weight: Int
    var isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, detail, weight
        case isEnabled = "is_enabled"
    }

    init(id: UUID = UUID(), name: String = "", detail: String = "", weight: Int = 1, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.detail = detail
        self.weight = weight
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        weight = try c.decodeIfPresent(Int.self, forKey: .weight) ?? 1
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// This month, counted from rows. From `usage_summary()`.
struct UsageSummary: Decodable, Sendable {
    let posted: Int
    let sentToDrafts: Int
    let scheduled: Int
    let videosMade: Int
    let plansWritten: Int
    let aiGenerations: Int
    let recordedCostCents: Int
    let byKind: [String: Double]

    enum CodingKeys: String, CodingKey {
        case posted, scheduled
        case sentToDrafts = "sent_to_drafts"
        case videosMade = "videos_made"
        case plansWritten = "plans_written"
        case aiGenerations = "ai_generations"
        case recordedCostCents = "recorded_cost_cents"
        case byKind = "by_kind"
    }
}
