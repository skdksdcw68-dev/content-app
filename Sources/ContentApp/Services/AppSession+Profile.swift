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
    nonisolated static func appleNonce() -> (raw: String, hashed: String) {
        let raw = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let hashed = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return (raw, hashed)
    }


    /// Makes this account permanent with the Apple ID just approved.
    ///
    /// Linking first, so the same user id keeps every brand, plan and video.
    /// If the Apple ID already belongs to an account -- signing back in after
    /// signing out, or a second phone -- linking is refused, and the right
    /// move is to become that account instead.
    func signInWithApple(_ authorization: ASAuthorization, nonce: String) async -> SignUpOutcome {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            return .failed("Apple didn’t send a sign-in token. Try again.")
        }
        let credentials = OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
        // Apple returns the name on the first authorization ever, and never
        // again -- so it is taken here rather than asked for on a screen.
        let appleName = credential.fullName
            .map { PersonNameComponentsFormatter().string(from: $0) }
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }

        /// Kept so that if signing in fails too, the reason reported is the
        /// one that actually started the trouble.
        var linkFailure: Error?

        do {
            if isAnonymous {
                do {
                    let linked = try await client.auth.linkIdentityWithIdToken(credentials: credentials)
                    readAccount(linked.user)
                    await adoptName(appleName)
                    return .linked
                } catch {
                    // Whatever went wrong, the token in hand is still a valid
                    // Apple sign-in, so signing in as that Apple ID is tried
                    // next and only its failure is reported. Matching on the
                    // words in the error meant any wording Supabase did not
                    // use -- linking refused, a rate limit, a network blip --
                    // came out as a dead button (Abel, 23 Sep 2026: "the
                    // apple sign in doesn't even work").
                    linkFailure = error
                }
            }
            _ = try await client.auth.signInWithIdToken(credentials: credentials)
            await restart(signingIn: true)
            await adoptName(appleName)
            return .switched
        } catch {
            return .failed(readableMessage(linkFailure ?? error))
        }
    }

    /// A name a provider handed over, taken only when there is none already:
    /// what somebody typed themselves always wins.
    func adoptName(_ provided: String?) async {
        guard let provided, !provided.isEmpty, displayName?.isEmpty != false else { return }
        await saveName(provided, promoting: "")
    }

    /// Signs out, then opens again as a new empty anonymous account. The Apple
    /// account and everything in it is still there to sign back in to.
    func signOut() async {
        // The default scope revokes the refresh token on the server, which
        // needs the network and fails on a bad one. Swallowing that left the
        // session on the phone and nothing happened at all (Abel, 23 Sep
        // 2026: "i cannot signout"). Local always follows, so the phone
        // forgets the account whether or not the server was reachable.
        do {
            try await client.auth.signOut()
        } catch {
            try? await client.auth.signOut(scope: .local)
        }
        // Or the next Google sign-in silently reuses the same account.
        GoogleAuth.signOut()
        // Setup belongs to a person, so signing out starts it again -- said
        // here rather than inferred from the id changing, which is the rule
        // that used to fire on every sign-in too.
        restartOnboarding()
        UserDefaults.standard.removeObject(forKey: Self.lastUserKey)
        onboardingAnswers = [:]
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

    // MARK: - Your name

    func refreshName() async {
        struct Row: Decodable, Sendable { let display_name: String? }
        guard let userID else { return }
        let rows: [Row]? = try? await client
            .from("profiles")
            .select("display_name")
            .eq("user_id", value: userID.uuidString)
            .execute()
            .value
        displayName = rows?.first?.display_name
    }

    /// Onboarding's first question. The name is the person's; "what you're
    /// promoting", when given, names the brand the planner writes for.
    @discardableResult
    func saveName(_ name: String, promoting: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.rpc("set_my_name", params: ["p_name": trimmed]).execute()
            displayName = trimmed.isEmpty ? nil : trimmed
            let product = promoting.trimmingCharacters(in: .whitespacesAndNewlines)
            if !product.isEmpty, let brand {
                await updateBrand(name: product, niche: brand.niche, audience: brand.audience)
            }
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// The letter in the round picture: the name's, else the brand's.
    var initial: String {
        let source = displayName ?? brand?.name ?? "A"
        return source.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "A"
    }

    // MARK: - A platform account

    /// The TikTok account, for everything that is TikTok-only (drafts, creator
    /// info, TikTok analytics). Healthy first.
    var tiktok: PlatformConnection? {
        connections.first { $0.platform == .tiktok && $0.isHealthy }
            ?? connections.first { $0.platform == .tiktok }
    }

    func connection(for platform: Platform) -> PlatformConnection? {
        connections.first { $0.platform == platform && $0.isHealthy }
            ?? connections.first { $0.platform == platform }
    }

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

    // MARK: - A post

    /// Removes a post from Autocast. The database refuses while it is on its
    /// way to TikTok; a video already there stays there.
    @discardableResult
    func deletePost(_ id: UUID) async -> Bool {
        do {
            try await client.rpc("delete_post", params: ["p_post": id.uuidString]).execute()
            await refreshPosts()
            await refreshPlan()
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
