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

    /// The one plan that is either running or waiting to be agreed to. A brand
    /// runs one at a time -- the database enforces it with a partial unique
    /// index -- so this is a single value rather than a list.
    private(set) var plan: ContentPlan?
    private(set) var planPosts: [PlannedPost] = []
    /// Separate from `isWorking` because writing a month takes twenty seconds
    /// and needs its own spinner in its own place, not a disabled tab bar.
    private(set) var isPlanning = false

    /// Generators the person has connected. Never their keys -- the server
    /// returns only that a credential exists and whether it last worked.
    private(set) var generators: [Generator] = []

    /// How this brand wants to be run. Carries the autopilot switch, which is
    /// off until somebody turns it on.
    private(set) var settings: BrandSettings?

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
            await refreshPlan()
            await refreshGenerators()
            await refreshSettings()
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
        // Ordered, because `limit(1)` without one asks Postgres for "any row"
        // and it is entitled to answer differently on different days. Anyone
        // who ends up with two brands would then see one of them at random.
        let existing: [Brand] = try await client
            .from("brands")
            .select()
            .order("created_at", ascending: true)
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
                .select("id,post_id,caption,state,privacy,is_aigc,consent_id,failure_reason,posts!inner(hook,status,created_at)")
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
    ///
    /// Passing `postID` fills in a post the plan already wrote instead of making
    /// a new one. Without it, adding a video for day 4 would create something
    /// unrelated and day 4 would stay empty.
    func addVideo(data: Data, filename: String, caption: String, postID: UUID? = nil) async {
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
                options: FunctionInvokeOptions(body: PrepareRequest(
                    connectionId: connection.id.uuidString,
                    storagePath: path,
                    caption: caption,
                    postId: postID?.uuidString
                ))
            )

            await refreshPosts()
            // The plan holds the status this just changed, so it goes stale the
            // moment a video lands against one of its days.
            if postID != nil { await refreshPlan() }
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
    ///
    /// Returns when it will go out, when the server was able to answer that. A
    /// post that came from a plan already has a slot, so approving it is the
    /// last thing a person has to do -- the scheduler takes it from there. A
    /// one-off upload has no slot, comes back with nil, and waits for a tap.
    @discardableResult
    func approve(
        postTargetID: UUID,
        privacy: String,
        disableComment: Bool,
        disableDuet: Bool,
        disableStitch: Bool,
        isAIGC: Bool
    ) async -> ApprovalOutcome? {
        isWorking = true
        defer { isWorking = false }

        do {
            let result: ApprovalResult = try await client.functions.invoke(
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
            await refreshPlan()
            return ApprovalOutcome(
                scheduledFor: result.scheduledFor.flatMap(PostgresTimestamp.parse)
            )
        } catch {
            lastError = readableMessage(error)
            return nil
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

/// A struct rather than a dictionary because `post_id` is optional, and a
/// `[String: String]` body cannot carry a missing key without the call site
/// building two different dictionaries.
private struct PrepareRequest: Encodable {
    let connectionId: String
    let storagePath: String
    let caption: String
    let postId: String?

    enum CodingKeys: String, CodingKey {
        case caption
        case connectionId = "connection_id"
        case storagePath = "storage_path"
        case postId = "post_id"
    }
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
    /// Null when nothing has said when this should go out, which is the case
    /// for anything that did not come from a plan.
    let scheduledFor: String?

    enum CodingKeys: String, CodingKey {
        case privacy
        case scheduledFor = "scheduled_for"
    }
}

/// What approving actually settled.
struct ApprovalOutcome: Sendable {
    let scheduledFor: Date?

    /// Nothing further is required of the person: the publisher owns it now.
    var isUnattended: Bool { scheduledFor != nil }
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

// MARK: - The plan

extension AppSession {
    /// The plan that is running, or the one waiting to be agreed to.
    ///
    /// Archived plans are excluded rather than sorted to the bottom: a plan you
    /// replaced last month is history, and history belongs on a screen that
    /// says so.
    func refreshPlan() async {
        guard brand != nil else { return }
        do {
            let plans: [ContentPlan] = try await client
                .from("content_plans")
                .select("id,title,status,starts_on,days,posts_per_day,brief,approved_at")
                .in("status", values: ["draft", "proposed", "active", "paused"])
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value

            plan = plans.first

            guard let current = plan else {
                planPosts = []
                return
            }

            planPosts = try await client
                .from("posts")
                .select("""
                    id,day_index,slot_index,hook,script,concept,rationale,\
                    status,scheduled_for,content_pillars(name)
                    """)
                .eq("plan_id", value: current.id.uuidString)
                .order("day_index", ascending: true)
                .order("slot_index", ascending: true)
                .execute()
                .value
        } catch {
            lastError = readableMessage(error)
        }
    }

    /// Asks for a month of content.
    ///
    /// Slow by the standards of a tap -- three model calls for thirty days --
    /// which is why it has its own flag rather than sharing `isWorking`. The
    /// result is a proposal: rows exist, nothing is scheduled, and the person
    /// has not agreed to anything yet.
    @discardableResult
    func proposePlan(brief: String, days: Int, postsPerDay: Int) async -> PlanProposal? {
        guard !isPlanning else { return nil }
        isPlanning = true
        defer { isPlanning = false }

        do {
            let proposal: PlanProposal = try await client.functions.invoke(
                "propose-plan",
                options: FunctionInvokeOptions(body: PlanRequest(
                    brief: brief,
                    days: days,
                    postsPerDay: postsPerDay
                ))
            )
            await refreshPlan()
            return proposal
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }

    /// The moment a person says yes. Every post in the plan gets a time, and
    /// the scheduler starts counting toward it.
    @discardableResult
    func activatePlan() async -> Bool {
        guard let planID = plan?.id else { return false }
        isWorking = true
        defer { isWorking = false }

        do {
            _ = try await client
                .rpc("activate_plan", params: ["p_plan_id": planID.uuidString])
                .execute()
            await refreshPlan()
            await refreshPosts()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// Throws the proposal away. The plan row survives as archived -- what the
    /// agent got wrong is worth more than the disk space.
    @discardableResult
    func discardPlan() async -> Bool {
        guard let planID = plan?.id else { return false }
        isWorking = true
        defer { isWorking = false }

        do {
            _ = try await client
                .rpc("discard_plan", params: ["p_plan_id": planID.uuidString])
                .execute()
            await refreshPlan()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }
}

private struct PlanRequest: Encodable {
    let brief: String
    let days: Int
    let postsPerDay: Int

    enum CodingKeys: String, CodingKey {
        case brief, days
        case postsPerDay = "posts_per_day"
    }
}

// MARK: - Generators

extension AppSession {
    /// What the person has connected. The keys themselves never come back.
    func refreshGenerators() async {
        do {
            generators = try await client
                .rpc("my_generators")
                .execute()
                .value
        } catch {
            lastError = readableMessage(error)
        }
    }

    /// Saves a key pair, after the server has proved it works.
    ///
    /// The probe is the server's, not ours: a client that could report its own
    /// probe result could store a key that has never been tried, and the first
    /// anyone would know is a job failing at three in the morning.
    @discardableResult
    func connectGenerator(keyID: String, keySecret: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }

        do {
            let _: ConnectedGenerator = try await client.functions.invoke(
                "connect-generator",
                options: FunctionInvokeOptions(body: [
                    "provider": "higgsfield",
                    "key_id": keyID,
                    "key_secret": keySecret,
                ])
            )
            await refreshGenerators()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    @discardableResult
    func forgetGenerator(_ id: UUID) async -> Bool {
        do {
            _ = try await client
                .rpc("forget_generator", params: ["p_credential_id": id.uuidString])
                .execute()
            await refreshGenerators()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    var hasWorkingGenerator: Bool { generators.contains(where: \.isWorking) }

    /// Starts making the video for one planned post.
    ///
    /// Returns as soon as the job is submitted, which is seconds -- generation
    /// itself takes minutes and finishes without the app. The post moves to
    /// `sourcing` and comes back as `needs_approval` when there is something to
    /// look at.
    @discardableResult
    func generateMedia(for postID: UUID) async -> Bool {
        isWorking = true
        defer { isWorking = false }

        do {
            let _: StartedJob = try await client.functions.invoke(
                "generate-media",
                options: FunctionInvokeOptions(body: ["post_id": postID.uuidString])
            )
            await refreshPlan()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }
}

private struct ConnectedGenerator: Decodable {
    let credentialId: String
    enum CodingKeys: String, CodingKey { case credentialId = "credential_id" }
}

private struct StartedJob: Decodable {
    let jobId: String
    enum CodingKeys: String, CodingKey { case jobId = "job_id" }
}

// MARK: - Autopilot

extension AppSession {
    func refreshSettings() async {
        guard let brandID = brand?.id else { return }
        do {
            let rows: [BrandSettings] = try await client
                .from("brand_settings")
                .select("is_on,posts_per_day,requires_approval,quiet_hours_start,quiet_hours_end,render_lead_hours")
                .eq("brand_id", value: brandID.uuidString)
                .execute()
                .value
            settings = rows.first
        } catch {
            lastError = readableMessage(error)
        }
    }

    /// Turns the autopilot on or off.
    ///
    /// This is the switch that decides whether media starts making itself. Off
    /// by default and never flipped on anyone's behalf: everything it enables
    /// spends the person's money without asking again.
    @discardableResult
    func setAutopilot(_ on: Bool) async -> Bool {
        guard let brandID = brand?.id else { return false }

        // Changed locally first so the toggle does not lag a round trip, and
        // put back if the write fails -- a switch that silently springs back is
        // worse than one that never moved.
        let previous = settings
        settings?.isOn = on

        do {
            _ = try await client
                .from("brand_settings")
                .update(["is_on": on])
                .eq("brand_id", value: brandID.uuidString)
                .execute()
            await refreshSettings()
            return true
        } catch {
            settings = previous
            lastError = readableMessage(error)
            return false
        }
    }
}
