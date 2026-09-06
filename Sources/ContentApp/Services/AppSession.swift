import Foundation
import Observation
import Supabase

/// The app's one connection to the backend, and everything it knows.
///
/// Replaces the old ContentStore, which faked a backend with a 700ms sleep and
/// a file of fixtures. Every property here is read from Postgres under row-level
/// security, so what the app can see and what it can change are decided by the
/// database rather than by this class remembering to be careful.
@MainActor
@Observable
final class AppSession {
    enum State: Equatable {
        case starting
        case ready
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var userID: UUID?
    private(set) var brand: Brand?
    private(set) var connections: [PlatformConnection] = []
    private(set) var isConnecting = false
    /// Any longer-running action the person started: uploading, approving,
    /// publishing. Drives the spinners and stops a second tap.
    private(set) var isWorking = false
    private(set) var posts: [PendingPost] = []

    /// Surfaced by the root view and cleared when acknowledged. Not an error log.
    var lastError: String?

    let client: SupabaseClient

    init() {
        client = SupabaseClient(
            supabaseURL: Config.supabaseURL,
            supabaseKey: Config.supabaseAnonKey
        )
    }

    // MARK: - Starting up

    /// Signs in and loads everything the app needs to draw its first screen.
    ///
    /// The sign-in is anonymous, which means the row in `auth.users` is real --
    /// RLS, brands and connections all behave normally -- but nobody has to get
    /// past a login wall to see whether the product is worth anything. Supabase
    /// can upgrade the same row to a permanent identity later without the person
    /// losing what they made.
    func start() async {
        do {
            try await signInIfNeeded()
            let user = try await client.auth.session.user
            userID = user.id
            try await loadBrand(for: user.id)
            await refreshConnections()
            await refreshPosts()
            state = .ready
        } catch {
            state = .failed(readableMessage(error))
        }
    }

    /// Reuses a stored session when there is one, and signs in anonymously when
    /// there is not. Deliberately avoids naming the SDK session type: it is also
    /// called Session, and two types with one name in the same file is a trap
    /// for whoever edits this next.
    private func signInIfNeeded() async throws {
        if (try? await client.auth.session) == nil {
            _ = try await client.auth.signInAnonymously()
        }
    }

    /// One brand for now. The schema supports several and the UI will, but
    /// shipping a brand switcher before there is a second brand is furniture.
    private func loadBrand(for userID: UUID) async throws {
        let existing: [Brand] = try await client
            .from("brands")
            .select()
            .limit(1)
            .execute()
            .value

        if let first = existing.first {
            brand = first
            return
        }

        let created: [Brand] = try await client
            .from("brands")
            .insert(NewBrand(
                userId: userID,
                name: "My brand",
                // The device's own zone, so the first schedule it proposes is
                // already in hours the person recognises.
                timezone: TimeZone.current.identifier
            ))
            .select()
            .execute()
            .value

        brand = created.first
    }

    func refreshConnections() async {
        guard let brandID = brand?.id else { return }
        do {
            connections = try await client
                .from("platform_connections")
                .select("id,brand_id,platform,username,display_name,avatar_url,scopes,status,connected_at,last_error")
                .eq("brand_id", value: brandID.uuidString)
                .order("connected_at", ascending: false)
                .execute()
                .value
        } catch {
            lastError = readableMessage(error)
        }
    }

    // MARK: - Connecting an account

    /// Runs the whole OAuth round trip and comes back with the account linked.
    ///
    /// The app never sees a token or the client secret. It asks the server for a
    /// URL, shows it, and waits for iOS to hand back the `autocast://` callback
    /// once the exchange has already happened server-side.
    func connectTikTok() async {
        guard let brandID = brand?.id, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        do {
            let start: AuthorizeStart = try await client.functions.invoke(
                "oauth-start",
                options: FunctionInvokeOptions(body: [
                    "brand_id": brandID.uuidString,
                    "platform": "tiktok",
                    "return_to": Config.oauthReturnURL,
                ])
            )

            guard let url = URL(string: start.authorizeURL) else {
                lastError = "The sign-in link came back malformed."
                return
            }

            let callback = try await WebAuth.run(url: url, scheme: Config.callbackScheme)
            try handle(callback: callback)
            await refreshConnections()
        } catch is CancellationError {
            // Closed the sheet. Not a failure worth a banner.
        } catch let error as WebAuth.Failure where error == .cancelled {
            // Same.
        } catch {
            lastError = readableMessage(error)
        }
    }

    /// Reads the result the callback carries. The work is already done by the
    /// time this runs; this only decides what to say about it.
    private func handle(callback: URL) throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        switch value("status") {
        case "connected":
            return
        case "denied":
            lastError = "You cancelled on TikTok, so nothing was connected."
        default:
            lastError = Self.message(forReason: value("reason"))
        }
    }

    private static func message(forReason reason: String?) -> String {
        switch reason {
        case "expired":
            return "That took a little too long. Try connecting again."
        case "exchange_failed":
            return "TikTok would not complete the sign-in. Try again."
        case "unknown_state", "missing_state":
            return "That sign-in did not match one we started. Try again."
        default:
            return "The account could not be connected."
        }
    }

    // MARK: - Errors

    /// Postgres and PostgREST errors are not written for people. Anything we do
    /// not recognise becomes something plain rather than a raw code.
    func readableMessage(_ error: Error) -> String {
        if let postgrest = error as? PostgrestError {
            return postgrest.message
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "No connection. Check your network and try again."
        }
        return error.localizedDescription
    }
}

private struct AuthorizeStart: Decodable {
    let authorizeURL: String

    enum CodingKeys: String, CodingKey {
        case authorizeURL = "authorize_url"
    }
}

// MARK: - Posts

extension AppSession {
    /// Everything queued for this brand, newest first.
    func refreshPosts() async {
        guard brand != nil else { return }
        do {
            posts = try await client
                .from("post_targets")
                .select("id,caption,state,privacy,is_aigc,consent_id,failure_reason,posts!inner(hook,status,created_at)")
                .order("id", ascending: false)
                .limit(50)
                .execute()
                .value
        } catch {
            lastError = readableMessage(error)
        }
    }

    /// Uploads a video the person picked and turns it into a post awaiting
    /// their approval.
    ///
    /// The file goes straight to Storage from here -- the storage policy scopes
    /// every object to its owner's folder, so there is no need to route bytes
    /// through a function. What the server does afterwards is decide the file is
    /// publishable, which is not a decision a client gets to make.
    func addVideo(data: Data, filename: String, caption: String) async {
        guard let connection = connections.first(where: \.isHealthy),
              let userID else {
            lastError = "Connect an account first."
            return
        }

        isWorking = true
        defer { isWorking = false }

        let path = "\(userID.uuidString)/\(UUID().uuidString)/\(filename)"

        do {
            _ = try await client.storage
                .from("media")
                .upload(path, data: data, options: FileOptions(contentType: mimeType(for: filename)))

            let _: PreparedPost = try await client.functions.invoke(
                "prepare-post",
                options: FunctionInvokeOptions(body: [
                    "connection_id": connection.id.uuidString,
                    "storage_path": path,
                    "caption": caption,
                ])
            )

            await refreshPosts()
        } catch {
            lastError = readableMessage(error)
        }
    }

    /// Reads what the account currently allows, straight from TikTok.
    func creatorInfo(for connectionID: UUID) async -> CreatorInfo? {
        do {
            return try await client.functions.invoke(
                "creator-info",
                options: FunctionInvokeOptions(body: ["connection_id": connectionID.uuidString])
            )
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }

    /// Records permission for one post, at one visibility.
    @discardableResult
    func approve(
        postTargetID: UUID,
        privacy: String,
        disableComment: Bool,
        disableDuet: Bool,
        disableStitch: Bool,
        isAIGC: Bool
    ) async -> Bool {
        isWorking = true
        defer { isWorking = false }

        do {
            let _: ApprovalResult = try await client.functions.invoke(
                "approve-post",
                options: FunctionInvokeOptions(body: ApprovalRequest(
                    postTargetId: postTargetID.uuidString,
                    privacy: privacy,
                    disableComment: disableComment,
                    disableDuet: disableDuet,
                    disableStitch: disableStitch,
                    isAigc: isAIGC,
                    brandContent: false,
                    brandOrganic: false
                ))
            )
            await refreshPosts()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// Sends it. `draft` puts it in the creator's TikTok drafts instead of
    /// posting, which is the path that needs no audit.
    @discardableResult
    func publish(postTargetID: UUID, draft: Bool) async -> String? {
        isWorking = true
        defer { isWorking = false }

        do {
            let result: PublishResult = try await client.functions.invoke(
                "publish-post",
                options: FunctionInvokeOptions(body: [
                    "post_target_id": postTargetID.uuidString,
                    "mode": draft ? "UPLOAD_TO_DRAFT" : "DIRECT_POST",
                ])
            )
            await refreshPosts()
            return result.state
        } catch {
            lastError = readableMessage(error)
            await refreshPosts()
            return nil
        }
    }

    private func mimeType(for filename: String) -> String {
        filename.lowercased().hasSuffix(".mov") ? "video/quicktime" : "video/mp4"
    }
}

private struct PreparedPost: Decodable {
    let postTargetId: String
    enum CodingKeys: String, CodingKey { case postTargetId = "post_target_id" }
}

private struct ApprovalRequest: Encodable {
    let postTargetId: String
    let privacy: String
    let disableComment: Bool
    let disableDuet: Bool
    let disableStitch: Bool
    let isAigc: Bool
    let brandContent: Bool
    let brandOrganic: Bool

    enum CodingKeys: String, CodingKey {
        case postTargetId = "post_target_id"
        case privacy
        case disableComment = "disable_comment"
        case disableDuet = "disable_duet"
        case disableStitch = "disable_stitch"
        case isAigc = "is_aigc"
        case brandContent = "brand_content"
        case brandOrganic = "brand_organic"
    }
}

private struct ApprovalResult: Decodable {
    let privacy: String
}

private struct PublishResult: Decodable {
    let state: String
    let reason: String?
}

// MARK: - Ideas

/// One idea from the writer. Not persisted -- ideas become posts only when a
/// person does something with them.
struct Idea: Identifiable, Decodable, Hashable, Sendable {
    var id: String { hook }
    let hook: String
    let caption: String
    let hashtags: [String]
    let rationale: String
}

extension AppSession {
    func ideas(for message: String) async -> [Idea] {
        do {
            let response: IdeaResponse = try await client.functions.invoke(
                "agent-chat",
                options: FunctionInvokeOptions(body: ["message": message])
            )
            return response.ideas
        } catch {
            lastError = readableMessage(error)
            return []
        }
    }
}

private struct IdeaResponse: Decodable {
    let ideas: [Idea]
}

// MARK: - Metrics

/// One video's numbers, as TikTok reports them.
struct VideoMetric: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let title: String
    let views: Int
    let likes: Int
    let comments: Int
    let shares: Int
}

struct Totals: Decodable, Hashable, Sendable {
    let views: Int
    let likes: Int
    let comments: Int
    let shares: Int
}

/// Nulls survive the whole way to the tiles on purpose: a figure the platform
/// did not return is shown as a dash, never as a zero.
struct Metrics: Decodable, Sendable {
    let username: String
    let followers: Int?
    let totalLikes: Int?
    let videoCount: Int?
    let recent: [VideoMetric]
    let totals: Totals

    enum CodingKeys: String, CodingKey {
        case username, recent, totals
        case followers
        case totalLikes = "total_likes"
        case videoCount = "video_count"
    }
}

extension AppSession {
    func metrics() async -> Metrics? {
        guard !connections.isEmpty else { return nil }
        do {
            return try await client.functions.invoke(
                "fetch-metrics",
                options: FunctionInvokeOptions(body: [String: String]())
            )
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }
}
