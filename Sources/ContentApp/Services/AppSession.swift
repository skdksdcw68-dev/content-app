import Foundation
import Observation
import Supabase
import SwiftUI
import UniformTypeIdentifiers

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
    /// Every app this person is marketing. The chosen one is `brand`.
    private(set) var brands: [Brand] = []
    private(set) var connections: [PlatformConnection] = []
    private(set) var isConnecting = false
    /// Any longer-running action the person started: uploading, approving,
    /// publishing. Drives the spinners and stops a second tap.
    internal(set) var isWorking = false
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

    /// Everything the planner is allowed to treat as true about this account.
    private(set) var facts: [BrandFact] = []

    /// Where first-run has got to. Restored before the first network call, so
    /// somebody halfway through does not watch the app flash past them.
    private(set) var onboarding: OnboardingStep = AppSession.storedOnboarding()
    /// Answers held in memory until the step is left, then written to the
    /// brand. Nothing here is a field of its own.
    internal(set) var onboardingAnswers: [String: Set<String>] = [:]
    /// The content style picked during onboarding, held with the answers and
    /// written to `brand_settings.style_slug` alongside them. Carried the same
    /// way, so signing in to another account takes it too.
    internal(set) var onboardingStyle: ContentTemplate?
    /// Where Back goes from the email screen, which can be reached from two
    /// places (Remi's `emailReturn`).
    internal(set) var emailReturn: OnboardingStep = .account
    /// Held between the email screen and the code screen.
    internal(set) var pendingEmail = ""
    internal(set) var pendingName = ""

    /// What is actually wrong with autopilot right now, worst first.
    ///
    /// Outcome checks rather than a heartbeat. `scheduler_health()` reported
    /// both cron loops firing every minute through three days in September in
    /// which the product made nothing at all -- so this asks whether anything
    /// came out, not whether the machine turned.
    private(set) var health: [HealthFinding] = []

    // NOTE: `internal(set)` rather than `private(set)`. Swift scopes
    // `private(set)` to the FILE, and AppSession is now legitimately split --
    // connectors and chat live in their own extensions. The intent is
    // unchanged and unenforceable either way inside one module: views read
    // these, AppSession writes them.

    /// Providers this person has connected, and what each can do.
    ///
    /// Named apart from `connections`, which is TikTok accounts: the platforms
    /// you post TO versus the providers you make things WITH.
    internal(set) var connectedProviders: [ProviderConnection] = []
    /// What could be connected that is not. Drives the Plus menu.
    internal(set) var connectable: [ConnectableProvider] = []

    /// Whether this is still the anonymous account the app opened with. Once
    /// Sign in with Apple is linked it is false, and the same user id -- with
    /// every row -- comes back on any phone.
    internal(set) var isAnonymous = true
    /// The Apple ID's email, when Apple shared one (it may be a relay address).
    internal(set) var accountEmail: String?
    /// What the person asked to be called. The account is the person, never
    /// their TikTok or YouTube (Abel, 19 Sep 2026).
    internal(set) var displayName: String?

    /// Autocast Pro, as the server decided it. Nil until first read.
    internal(set) var subscription: MyPlan?
    /// Set when a Pro limit is reached anywhere; the root shows the paywall.
    var showingPaywall = false

    /// The one navigation stack, around the tabs. A tab root goes somewhere
    /// by appending a route here; see `AppRoute`.
    var path = NavigationPath()

    func push(_ route: AppRoute) {
        path.append(route)
    }

    /// Videos on their way up from this phone right now, so Home can show
    /// them as tiles that say "Uploading" instead of a spinner somewhere
    /// else (Abel, 22 Sep 2026: "say uploading on the home... so on the home
    /// it counts"). Added when Post is pressed, removed once the post exists.
    var uploads: [LocalUpload] = []

    struct LocalUpload: Identifiable, Equatable {
        let id = UUID()
        let poster: UIImage?
        let caption: String
        static func == (a: LocalUpload, b: LocalUpload) -> Bool { a.id == b.id }
    }

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
            readAccount(user)
            // A different person than last launch -- signed out, or a session
            // that expired and came back as a fresh anonymous account. Setup
            // belongs to a person, so it starts again (Abel, 21 Sep 2026:
            // "signout doesn't let you go to the onboarding").
            let remembered = UserDefaults.standard.string(forKey: Self.lastUserKey)
            if remembered != user.id.uuidString {
                UserDefaults.standard.set(user.id.uuidString, forKey: Self.lastUserKey)
                // ...but signing in is not "a different person". It is this
                // person finishing, and the id changes because their identity
                // already had an account. Resetting here sent them back to
                // question one every single time they signed in, forever
                // (Abel, 23 Sep 2026: "with google it redirects me to the
                // onboarding, i did that, then it redirects me to the
                // onboarding again"). Only an unasked-for change of user --
                // signing out, or a session that lapsed into a fresh
                // anonymous one -- starts setup again.
                if remembered != nil, !isSigningIn { setOnboarding(.welcome) }
            }
            // Only what decides which screen comes first is waited for: the
            // person, the brand, and the accounts. Everything else loads
            // behind the first screen, all at once -- ten reads in a row
            // were the whole reason the mark sat there so long (Abel,
            // 23 Sep 2026: "the splash is taking much time, make the app
            // load in the back").
            async let name: Void = refreshName()
            async let connections: Void = refreshConnections()
            try await loadBrand(for: user.id)
            _ = await (name, connections)
            // An account is how somebody gets in (Abel, 21 Sep 2026:
            // "registration and onboarding completion is must"). Anyone who
            // finished setup before that rule, or whose session lapsed into a
            // fresh anonymous one, lands on the account screen with their
            // answers intact rather than in a half-owned app.
            if isAnonymous, onboarding == .done { setOnboarding(.account) }
            // And the questions are not optional either. An account that
            // reached the app without answering them -- through the Log in
            // door, or from before this rule -- answers them now. Unless they
            // were answered a moment ago on the way in, in which case they
            // are written to this account rather than asked twice.
            if onboarding == .done, let brand, !brand.answeredOnboarding {
                await carryAnswersToThisAccount()
                if self.brand?.answeredOnboarding != true { setOnboarding(.question(0)) }
            }
            state = .ready

            // The rest, together, behind the screen that is already up.
            // Every screen that needs one of these draws its skeleton until
            // it lands, and refreshes it again on its own.
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.refreshPosts() }
                    group.addTask { await self.refreshPlan() }
                    group.addTask { await self.refreshGenerators() }
                    // Signed-in providers alongside pasted keys -- otherwise
                    // `hasWorkingGenerator` reads false until something
                    // happens to refresh them.
                    group.addTask { await self.refreshConnectedProviders() }
                    group.addTask { await self.refreshConnectable() }
                    group.addTask { await self.refreshSettings() }
                    group.addTask { await self.refreshHealth() }
                    group.addTask { await self.refreshSubscription() }
                    // Anything bought on another device, or renewed while closed.
                    group.addTask { await self.syncPurchases() }
                }
            }
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

    func readAccount(_ user: User) {
        isAnonymous = user.isAnonymous
        accountEmail = user.email?.isEmpty == false ? user.email : nil
    }

    /// True only while a sign-in somebody asked for is changing the user id
    /// underneath us. `start()` reads it to tell "they signed in" apart from
    /// "they are not who they were last launch".
    private(set) var isSigningIn = false

    /// Starts over as whoever is signed in now -- after signing out, deleting
    /// the account, or signing in to an Apple ID that already had one.
    /// Everything on screen belonged to the previous user, so all of it goes
    /// before the next one is read.
    ///
    /// - Parameter signingIn: set by the sign-in paths, so the change of user
    ///   is not mistaken for somebody new arriving and setup is not restarted.
    func restart(signingIn: Bool = false) async {
        isSigningIn = signingIn
        defer { isSigningIn = false }
        state = .starting
        userID = nil
        brand = nil
        brands = []
        connections = []
        posts = []
        plan = nil
        planPosts = []
        generators = []
        settings = nil
        facts = []
        health = []
        connectedProviders = []
        connectable = []
        isAnonymous = true
        accountEmail = nil
        displayName = nil
        subscription = nil
        UserDefaults.standard.removeObject(forKey: Self.chosenBrandKey)
        await start()
    }

    /// Every app this person markets, and which one is being looked at.
    ///
    /// One brand was never the shape of this: the point is that it runs the
    /// marketing for ALL of them, and each needs its own plan, memory,
    /// accounts and schedule. The schema was built that way from the start --
    /// brand_id is on memory, settings, pillars, threads, runs, connections,
    /// plans and posts -- so this is the app catching up.
    ///
    /// The chosen one is remembered between launches: reopening on the wrong
    /// brand is how the wrong thing gets posted.
    private func loadBrand(for userID: UUID) async throws {
        // Ordered, because an unordered read asks Postgres for "any row" and
        // it is entitled to answer differently on different days.
        let existing: [Brand] = try await client
            .from("brands")
            .select()
            .order("created_at", ascending: true)
            .execute()
            .value

        if !existing.isEmpty {
            brands = existing
            let remembered = UserDefaults.standard.string(forKey: Self.chosenBrandKey)
                .flatMap(UUID.init(uuidString:))
            brand = existing.first { $0.id == remembered } ?? existing.first
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
        brands = created
    }

    /// Which brand everything else is about, between launches.
    private static let chosenBrandKey = "autocast.brand"
    /// Who was signed in last launch, to notice when it is somebody else.
    static let lastUserKey = "autocast.lastUser"

    /// Look at another one. Everything brand-shaped is read again: leaving one
    /// app's posts on screen under another app's name is worse than a moment
    /// of emptiness.
    func switchBrand(to id: UUID) async {
        guard let next = brands.first(where: { $0.id == id }), next.id != brand?.id else { return }
        brand = next
        UserDefaults.standard.set(id.uuidString, forKey: Self.chosenBrandKey)
        posts = []
        plan = nil
        planPosts = []
        connections = []
        await refreshConnections()
        await refreshPosts()
        await refreshPlan()
        await refreshSettings()
        await refreshHealth()
    }

    /// Another app to market. Named now; what it is for the agent asks once,
    /// in its own words, when it is the one being looked at.
    @discardableResult
    func addBrand(named name: String) async -> Brand? {
        guard let userID else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let created: [Brand] = try await client
                .from("brands")
                .insert(NewBrand(userId: userID, name: trimmed, timezone: TimeZone.current.identifier))
                .select()
                .execute()
                .value
            guard let made = created.first else { return nil }
            brands.append(made)
            await switchBrand(to: made.id)
            return made
        } catch {
            lastError = readableMessage(error)
            return nil
        }
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
            report("refreshConnections", error)
        }
    }

    // MARK: - Connecting an account

    /// Runs the whole OAuth round trip and comes back with the account linked.
    ///
    /// The app never sees a token or the client secret. It asks the server for a
    /// URL, shows it, and waits for iOS to hand back the `autocast://` callback
    /// once the exchange has already happened server-side.
    func connectTikTok() async { await connect(.tiktok) }

    /// Any platform: TikTok, YouTube (shorts) or Instagram (reels). Same round
    /// trip; the server picks the provider.
    func connect(_ platform: Platform) async {
        guard let brandID = brand?.id, !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        do {
            let start: AuthorizeStart = try await client.functions.invoke(
                "oauth-start",
                options: FunctionInvokeOptions(body: [
                    "brand_id": brandID.uuidString,
                    "platform": platform.rawValue,
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
    /// A background load that failed. Logged with the name of the call --
    /// "the data couldn't be read" tells nobody which data -- and never shown
    /// as an alert: these run at launch and on every refresh, and the next
    /// pass fixes most of them.
    func report(_ call: String, _ error: Error) {
        print("[autocast] \(call) failed: \(error)")
    }

    func readableMessage(_ error: Error) -> String {
        if let postgrest = error as? PostgrestError {
            return postgrest.message
        }
        // A function's own words, and the paywall when it says a Pro limit
        // was reached (HTTP 402, see _shared/quota.ts).
        if case let FunctionsError.httpError(code, data) = error {
            if code == 402 { showingPaywall = true }
            struct Body: Decodable { let error: String? }
            if let message = (try? JSONDecoder().decode(Body.self, from: data))?.error, !message.isEmpty {
                return message
            }
        }
        // A request cancelled because its screen went away is not an error
        // and must not become an alert. Switching tabs quickly cancelled the
        // last tab's loads and every one of them said "No connection" (Abel,
        // 23 Sep 2026: "switching fast from page to page says connection or
        // this did not work"). Empty means "nothing to show"; the root's
        // alert ignores it.
        if error is CancellationError { return "" }
        if let url = error as? URLError, url.code == .cancelled { return "" }
        if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { return "" }
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
                .select("id,post_id,caption,state,privacy,is_aigc,consent_id,failure_reason,published_at,metrics,posts!inner(hook,status,created_at)")
                .order("id", ascending: false)
                .limit(50)
                .execute()
                .value
        } catch {
            report("refreshPosts", error)
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
        guard let connection = tiktok, let userID else {
            lastError = "Connect an account first."
            return
        }

        isWorking = true
        defer { isWorking = false }

        // Lowercase: the storage policy and prepare-post compare against
        // auth.uid(), which Postgres prints in lowercase. uuidString is upper.
        let path = "\(userID.uuidString.lowercased())/\(UUID().uuidString.lowercased())/\(filename)"

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
            let info: CreatorInfo = try await retryingDroppedConnection {
                try await client.functions.invoke(
                    "creator-info",
                    options: FunctionInvokeOptions(body: ["connection_id": connectionID.uuidString])
                )
            }
            return info
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
        isAIGC: Bool,
        runAt: Date? = nil,
        postNow: Bool = false,
        toDrafts: Bool = false,
        brandContent: Bool = false,
        brandOrganic: Bool = false
    ) async -> ApprovalOutcome? {
        isWorking = true
        defer { isWorking = false }

        do {
            let request = ApprovalRequest(
                postTargetId: postTargetID.uuidString,
                privacy: privacy,
                disableComment: disableComment,
                disableDuet: disableDuet,
                disableStitch: disableStitch,
                isAigc: isAIGC,
                brandContent: brandContent,
                brandOrganic: brandOrganic,
                runAt: runAt.map { ISO8601DateFormatter().string(from: $0) },
                postNow: postNow ? true : nil,
                mode: toDrafts ? "UPLOAD_TO_DRAFT" : nil
            )
            let result: ApprovalResult = try await retryingDroppedConnection {
                try await client.functions.invoke("approve-post", options: FunctionInvokeOptions(body: request))
            }
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
    /// When to post it, if chosen on the review screen.
    let runAt: String?
    /// Queue it for this minute.
    let postNow: Bool?
    /// "UPLOAD_TO_DRAFT" sends it to the creator's TikTok drafts.
    let mode: String?

    enum CodingKeys: String, CodingKey {
        case runAt = "run_at"
        case postNow = "post_now"
        case mode
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
    /// Today's numbers for the brand on screen. Also writes a reading into the
    /// history (0037), so opening Analytics adds a point to its own chart.
    func metrics() async -> Metrics? {
        guard !connections.isEmpty else { return nil }
        do {
            return try await client.functions.invoke(
                "fetch-metrics",
                options: FunctionInvokeOptions(body: ["brand_id": brand.map { "\($0.id)" } ?? ""])
            )
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }

    // The report, the learning and the exports live in AppSession+Analytics.
}

// MARK: - The plan

extension AppSession {
    /// The plan that is running, or the one waiting to be agreed to.
    ///
    /// Archived plans are excluded rather than sorted to the bottom: a plan you
    /// replaced last month is history, and history belongs on a screen that
    /// says so.
    func refreshPlan() async {
        guard let brand else { return }
        do {
            // This brand only. Without the filter the newest plan of ANY brand
            // showed, so Drobe could open Remi Snap's month.
            let plans: [ContentPlan] = try await client
                .from("content_plans")
                .select("id,title,status,starts_on,days,posts_per_day,brief,approved_at,objective,platforms,template_slug,duration_s")
                .eq("brand_id", value: brand.id.uuidString)
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
            report("refreshPlan", error)
        }
    }

    /// Asks for a month of content.
    ///
    /// Slow by the standards of a tap -- three model calls for thirty days --
    /// which is why it has its own flag rather than sharing `isWorking`. The
    /// result is a proposal: rows exist, nothing is scheduled, and the person
    /// has not agreed to anything yet.
    @discardableResult
    /// The content styles on offer, in the catalogue's order.
    func templates() async -> [ContentTemplate] {
        do {
            return try await client
                .from("content_templates")
                .select("slug,name,tagline,category,symbol,art,pillars,visual_style,workflow")
                .eq("enabled", value: true)
                .order("sort")
                .execute()
                .value
        } catch {
            report("templates", error)
            return []
        }
    }

    func proposePlan(
        brief: String,
        days: Int,
        postsPerDay: Int,
        platforms: [String] = [],
        template: String? = nil,
        durationSeconds: Int? = nil
    ) async -> PlanProposal? {
        guard !isPlanning else { return nil }
        isPlanning = true
        defer { isPlanning = false }

        do {
            let proposal: PlanProposal = try await client.functions.invoke(
                "propose-plan",
                options: FunctionInvokeOptions(body: PlanRequest(
                    brief: brief,
                    days: days,
                    postsPerDay: postsPerDay,
                    brandId: brand?.id.uuidString,
                    platforms: platforms.isEmpty ? nil : platforms,
                    template: template,
                    durationSeconds: durationSeconds
                ))
            )
            await refreshSettings()
            await refreshPlan()
            return proposal
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }

    /// A plan the person already has -- a DOCX, PDF, ZIP or text file, or text
    /// pasted from ChatGPT -- read into a proposal. Only the posts in it are
    /// kept; nothing is written for them. The file goes to their own uploads
    /// folder first, which is the only place the server will read from.
    @discardableResult
    func importPlan(file: URL? = nil, text: String? = nil) async -> PlanProposal? {
        guard !isPlanning, let userID else { return nil }
        isPlanning = true
        defer { isPlanning = false }

        do {
            var path: String?
            var fileName: String?
            if let file {
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: file)
                guard data.count <= 25 * 1024 * 1024 else {
                    lastError = "That file is over 25 MB. Try a smaller one, or paste the plan."
                    return nil
                }
                let ext = file.pathExtension.lowercased().isEmpty ? "txt" : file.pathExtension.lowercased()
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                let key = "\(userID.uuidString.lowercased())/uploads/\(UUID().uuidString.lowercased()).\(ext)"
                _ = try await client.storage
                    .from("artifacts")
                    .upload(key, data: data, options: FileOptions(contentType: mime))
                path = key
                fileName = file.lastPathComponent
            }

            let proposal: PlanProposal = try await client.functions.invoke(
                "import-plan",
                options: FunctionInvokeOptions(body: ImportRequest(
                    brandId: brand?.id.uuidString,
                    path: path,
                    fileName: fileName,
                    text: text
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

    /// Deletes the current plan whatever its state (0059). What already went
    /// out stays; everything still to come goes with it.
    func deletePlan() async -> Bool {
        guard let planID = plan?.id else { return false }
        isWorking = true
        defer { isWorking = false }

        do {
            _ = try await client
                .rpc("delete_plan", params: ["p_plan": planID.uuidString])
                .execute()
            await refreshPlan()
            await refreshPosts()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }
}

private struct ImportRequest: Encodable {
    let brandId: String?
    let path: String?
    let fileName: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case path, text
        case brandId = "brand_id"
        case fileName = "file_name"
    }
}

private struct PlanRequest: Encodable {
    let brief: String
    let days: Int
    let postsPerDay: Int
    /// The brand on screen. Without it the planner took the first brand, so a
    /// plan asked for from one app could be written for another.
    let brandId: String?
    /// Where the posts go: "tiktok", "reels", "shorts".
    let platforms: [String]?
    /// A content style (content_templates.slug), for a series.
    let template: String?
    /// How long each video should be. Nil lets the model decide.
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case brief, days, platforms, template
        case postsPerDay = "posts_per_day"
        case brandId = "brand_id"
        case durationSeconds = "duration_s"
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
            report("refreshGenerators", error)
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

    /// Anything that can actually make a video: a key pasted the old way, or a
    /// provider connected by signing in that reported the capability. Counting
    /// only pasted keys left the Autopilot switch disabled for somebody who had
    /// connected Higgsfield properly.
    var hasWorkingGenerator: Bool {
        generators.contains(where: \.isWorking)
            || connectedProviders.contains { $0.isHealthy && $0.capabilities.contains("video_generation") }
    }

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
    /// Asks the database what is wrong with this account.
    ///
    /// Cheap, and read on every start: the whole point is that nobody has to
    /// go looking. A failure here is deliberately silent -- a monitor that
    /// raises its own error banner when it cannot run is worse than one that
    /// says nothing, because the thing it is monitoring may well be fine.
    func refreshHealth() async {
        do {
            health = try await client.rpc("autopilot_health").execute().value
        } catch {
            health = []
        }
    }

    func refreshSettings() async {
        guard let brandID = brand?.id else { return }
        do {
            let rows: [BrandSettings] = try await client
                .from("brand_settings")
                .select("is_on,posts_per_day,requires_approval,quiet_hours_start,quiet_hours_end,render_lead_hours,chat_instructions,style_slug")
                .eq("brand_id", value: brandID.uuidString)
                .execute()
                .value
            settings = rows.first
        } catch {
            report("refreshSettings", error)
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

// MARK: - What it knows about you

extension AppSession {
    func refreshFacts() async {
        guard let brandID = brand?.id else { return }
        do {
            facts = try await client
                .from("brand_memory")
                .select("id,fact,source,created_at")
                .eq("brand_id", value: brandID.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
        } catch {
            report("refreshFacts", error)
        }
    }

    /// Adds something the planner may then rely on.
    ///
    /// This is the only source of specifics it has. The planner is forbidden
    /// from inventing a number, a price or a shipped feature, so anything it
    /// says concretely came from here or from the brand description.
    @discardableResult
    func remember(_ fact: String) async -> Bool {
        guard let brandID = brand?.id, let userID else { return false }
        isWorking = true
        defer { isWorking = false }

        do {
            _ = try await client
                .from("brand_memory")
                .insert(NewFact(userId: userID, brandId: brandID, fact: fact, source: "user"))
                .execute()
            await refreshFacts()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    @discardableResult
    func forget(_ factID: UUID) async -> Bool {
        do {
            _ = try await client
                .from("brand_memory")
                .delete()
                .eq("id", value: factID.uuidString)
                .execute()
            await refreshFacts()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// Saves the description the planner writes from.
    @discardableResult
    func updateBrand(name: String, niche: String, audience: String) async -> Bool {
        guard let brandID = brand?.id else { return false }
        isWorking = true
        defer { isWorking = false }

        do {
            let updated: [Brand] = try await client
                .from("brands")
                .update([
                    "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
                    "niche": niche.trimmingCharacters(in: .whitespacesAndNewlines),
                    "audience": audience.trimmingCharacters(in: .whitespacesAndNewlines),
                ])
                .eq("id", value: brandID.uuidString)
                .select()
                .execute()
                .value
            brand = updated.first ?? brand
            if let changed = updated.first, let index = brands.firstIndex(where: { $0.id == changed.id }) {
                brands[index] = changed
            }
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// Saves the whole Brand page at once: the description the planner writes
    /// from, the questionnaire, and the voice (which the planner reads from
    /// `brand_settings.tone`).
    @discardableResult
    func saveBrandProfile(name: String, niche: String, audience: String,
                          profile: [String: BrandAnswer], tone: String?) async -> Bool {
        guard let brandID = brand?.id else { return false }
        struct Fields: Encodable, Sendable {
            let name: String
            let niche: String
            let audience: String
            let profile: [String: BrandAnswer]
        }
        struct Tone: Encodable, Sendable { let tone: String }
        let clean = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        do {
            let updated: [Brand] = try await client
                .from("brands")
                .update(Fields(name: clean(name), niche: clean(niche), audience: clean(audience), profile: profile))
                .eq("id", value: brandID.uuidString)
                .select()
                .execute()
                .value
            if let changed = updated.first {
                brand = changed
                if let index = brands.firstIndex(where: { $0.id == changed.id }) { brands[index] = changed }
            }
            if let tone {
                try await client
                    .from("brand_settings")
                    .update(Tone(tone: tone))
                    .eq("brand_id", value: brandID.uuidString)
                    .execute()
            }
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }

    /// Posting hours: the quiet window and how many a day in `brand_settings`,
    /// and the zone every one of those hours is read in, on the brand.
    @discardableResult
    func updateSchedule(quietStart: Int, quietEnd: Int, postsPerDay: Int, timezone: String) async -> Bool {
        guard let brandID = brand?.id else { return false }
        struct Hours: Encodable, Sendable {
            let quiet_hours_start: Int
            let quiet_hours_end: Int
            let posts_per_day: Int
        }
        do {
            try await client
                .from("brand_settings")
                .update(Hours(quiet_hours_start: quietStart, quiet_hours_end: quietEnd, posts_per_day: postsPerDay))
                .eq("brand_id", value: brandID.uuidString)
                .execute()
            if timezone != brand?.timezone {
                let updated: [Brand] = try await client
                    .from("brands")
                    .update(["timezone": timezone])
                    .eq("id", value: brandID.uuidString)
                    .select()
                    .execute()
                    .value
                if let changed = updated.first {
                    brand = changed
                    if let index = brands.firstIndex(where: { $0.id == changed.id }) { brands[index] = changed }
                }
            }
            await refreshSettings()
            return true
        } catch {
            lastError = readableMessage(error)
            return false
        }
    }
}

private struct NewFact: Encodable {
    let userId: UUID
    let brandId: UUID
    let fact: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case fact, source
        case userId = "user_id"
        case brandId = "brand_id"
    }
}

// MARK: - First run

extension AppSession {
    private static let onboardingKey = "onboarding.step"

    /// Restores where somebody was, or starts them at the beginning.
    ///
    /// Read from UserDefaults rather than the database on purpose: this decides
    /// what to draw before the first network call has finished, and a person
    /// mid-flow should not see the app flash past them while a query resolves.
    static func storedOnboarding() -> OnboardingStep {
        guard let raw = UserDefaults.standard.string(forKey: onboardingKey),
              let step = OnboardingStep(stored: raw)
        else { return .welcome }
        return step
    }

    func onboardingNext() {
        switch onboarding {
        case .welcome:
            setOnboarding(.question(0))
        case .question(let index):
            let next = index + 1
            if next < OnboardingQuestion.all.count {
                setOnboarding(.question(next))
            } else {
                // The questions are done; the style is the last thing asked.
                setOnboarding(.contentStyle)
            }
        case .contentStyle:
            // Everything answered: the ring screen covers the writing.
            setOnboarding(.building)
            Task { await saveAnswers() }
        case .building:
            setOnboarding(.included)
        case .included:
            setOnboarding(.account)
        case .verified:
            // Into the app only if this account has answered the questions.
            // Somebody who came in through Log in with an account that never
            // did gets them now, with the account already theirs -- but
            // answers given on the way in are carried over first, so nobody
            // is asked the same twelve questions twice.
            if let brand, !brand.answeredOnboarding {
                // The screen they are on stays up for the moment this takes,
                // rather than flashing a question that is about to be
                // answered for them.
                Task {
                    await self.carryAnswersToThisAccount()
                    self.setOnboarding(self.brand?.answeredOnboarding == true ? .done : .question(0))
                }
            } else {
                setOnboarding(.done)
            }
        // The account screen is left by choosing something on it: a provider,
        // the email door, or Continue as Guest.
        case .account, .email, .code, .done:
            break
        }
    }

    /// Remi's guard: a choice screen advances itself a moment after a tap, and
    /// a second tap inside that moment would otherwise skip a question nobody
    /// saw.
    func onboardingNext(from step: OnboardingStep) {
        guard onboarding == step else { return }
        onboardingNext()
    }

    /// Where the flow goes on the account screens, which are not a queue.
    func onboarding(goTo step: OnboardingStep) { setOnboarding(step) }



    func onboardingBack() {
        switch onboarding {
        case .question(let index):
            setOnboarding(index == 0 ? .welcome : .question(index - 1))
        case .contentStyle:
            setOnboarding(.question(max(0, OnboardingQuestion.all.count - 1)))
        case .included:
            setOnboarding(.contentStyle)
        case .account:
            setOnboarding(.included)
        case .email:
            // Back from the email door returns to wherever it was opened from:
            // the account screen for a sign-up, the welcome screen for a log in.
            setOnboarding(emailReturn)
        case .code(let mode):
            setOnboarding(.email(mode))
        case .welcome, .building, .verified, .done:
            break
        }
    }

    /// Lets somebody run through it again from Profile, which is also the only
    /// way to see it during development without deleting the app.
    func restartOnboarding() { setOnboarding(.welcome) }

    /// Opens the email door, remembering the screen to come back to.
    func goToEmail(_ mode: OnboardingStep.Mode) {
        emailReturn = mode == .login && onboarding == .welcome ? .welcome : .account
        setOnboarding(.email(mode))
    }

    private func setOnboarding(_ step: OnboardingStep) {
        onboarding = step
        UserDefaults.standard.set(step.storedValue, forKey: Self.onboardingKey)
    }

    func onboardingToggle(_ option: OnboardingQuestion.Option, in question: OnboardingQuestion) {
        var chosen = onboardingAnswers[question.id] ?? []

        if question.selection == .single {
            chosen = chosen.contains(option.id) ? [] : [option.id]
        } else if chosen.contains(option.id) {
            chosen.remove(option.id)
        } else {
            chosen.insert(option.id)
        }

        onboardingAnswers[question.id] = chosen
    }

    /// Writes the answers where they already live.
    ///
    /// Onboarding is not a second home for any of this: the two questions fill
    /// `brands.niche` and `brands.audience`, and the voice fills
    /// `brand_settings.tone`. Coming back to You → Your brand afterwards shows
    /// exactly what was answered here, editable, which is what stops the two
    /// screens disagreeing about which one is true.
    /// How many of the twelve are answered in memory right now.
    ///
    /// The questions are answered before there is an account to save them to.
    /// If signing in then lands on an account that already existed, the answers
    /// are still here -- so they are written to that account rather than asked
    /// for a second time (Abel, 23 Sep 2026: "it redirects me to the onboarding
    /// again").
    private var answersHeldInMemory: Int {
        OnboardingQuestion.all.filter { !(onboardingAnswers[$0.id] ?? []).isEmpty }.count
    }

    /// The style chosen on the way in belongs to whichever account they end up
    /// on, the same as the answers.
    private func carryStyleToThisAccount() async {
        guard let slug = onboardingStyle?.slug, settings?.styleSlug == nil else { return }
        await saveStyleSlug(slug)
    }

    func carryAnswersToThisAccount() async {
        await carryStyleToThisAccount()
        guard let brand, !brand.answeredOnboarding else { return }
        // The same bar `Brand.answeredOnboarding` uses, so carrying them over
        // always clears the gate that sent us here.
        guard answersHeldInMemory >= max(1, OnboardingQuestion.all.count / 2) else { return }
        await saveAnswers()
    }

    private func saveAnswers() async {
        // A brand that has not loaded yet is not a reason to throw the answers
        // away: they were the whole point of the last two minutes.
        if brand == nil, let userID { try? await loadBrand(for: userID) }
        guard let brand else { return }

        let labels = { (question: OnboardingQuestion) -> [String] in
            let chosen = self.onboardingAnswers[question.id] ?? []
            return question.options.filter { chosen.contains($0.id) }.map(\.label)
        }

        // Into the same profile the Brand page edits, keeping anything it
        // already holds.
        var profile = brand.profile ?? [:]
        for question in OnboardingQuestion.all {
            let picked = labels(question)
            if !picked.isEmpty { profile[question.id] = BrandAnswer(title: question.title, answers: picked) }
        }

        // The two sentences the planner reads, filled only when still empty:
        // what the person typed on the Brand page always wins.
        let kind = labels(BrandQuestions.category).first
        let audience = labels(BrandQuestions.audience)
        let niche = brand.niche.isEmpty ? (kind?.lowercased() ?? "") : brand.niche
        let who = brand.audience.isEmpty ? audience.joined(separator: ", ") : brand.audience

        let voice = BrandQuestions.voice.options.first { (onboardingAnswers["voice"] ?? []).contains($0.id) }
        let tone = voice.map { "\($0.label). \($0.detail ?? "")".trimmingCharacters(in: .whitespaces) }

        // The style reads as an answer on the Brand page like the rest, and
        // the slug it came from goes where the series flow can find it.
        if let style = onboardingStyle {
            profile["content_style"] = BrandAnswer(title: "Content style", answers: [style.name])
        }

        // Silent on failure: a lost answer is a slightly worse plan later,
        // not a broken app now, and an alert would land on a moved-on screen.
        _ = await saveBrandProfile(name: brand.name, niche: niche, audience: who, profile: profile, tone: tone)
        if let slug = onboardingStyle?.slug { await saveStyleSlug(slug) }
        lastError = nil
        await refreshSettings()
    }

    /// Remembers the chosen style on the brand (0060), so the series flow
    /// opens on it and a reinstall does not lose it.
    func saveStyleSlug(_ slug: String) async {
        guard let brandID = brand?.id else { return }
        struct Fields: Encodable, Sendable { let style_slug: String }
        _ = try? await client
            .from("brand_settings")
            .update(Fields(style_slug: slug))
            .eq("brand_id", value: brandID.uuidString)
            .execute()
    }
}
