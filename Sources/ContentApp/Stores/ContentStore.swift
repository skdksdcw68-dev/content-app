import Foundation
import Observation

/// The single source of truth for the queue, the connected accounts and the
/// autopilot's settings.
///
/// Everything that a real backend would touch lives behind `connect()`,
/// `refresh()` and `publishNow(_:)`. No view knows where a post came from, so
/// wiring up the real thing does not touch the UI:
///
///     connect()      <- OAuth to the platform, create the Supabase session
///     posts          <- what the planner has produced so far
///     pillars        <- what the person told it to stay within
///     settings       <- what it is allowed to decide
@MainActor
@Observable
final class ContentStore {
    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
    }

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var posts: [ContentPost] = []
    private(set) var pillars: [ContentPillar] = []
    private(set) var accounts: [SocialAccount] = []
    var settings = AutopilotSettings()

    /// Nil means "no filter" -- the chip row shows nothing selected.
    var statusFilter: PostStatus?
    var searchText: String = ""

    /// Set when something the person triggered failed. The views surface it and
    /// clear it; it is not an error log.
    var lastError: String?

    init() {}

    // MARK: - Connection

    /// Links a publishing account and loads the queue.
    ///
    /// STUBBED. Today this waits a beat and loads pre-planned sample content so
    /// the whole flow -- connect, review, approve, publish, disconnect -- is
    /// real and testable on device. The real version signs in to the platform,
    /// exchanges the token, and pages the planner's output out of Supabase.
    func connect(to platform: Platform = .tiktok) async {
        guard connectionState != .connected else { return }
        connectionState = .connecting
        try? await Task.sleep(for: .milliseconds(700))

        accounts = [SocialAccount(platform: platform, handle: "@yourhandle")]
        pillars = Self.samplePillars
        posts = Self.samplePosts(pillars: pillars)
        settings.platforms = [platform]
        connectionState = .connected
    }

    func disconnect() {
        connectionState = .disconnected
        posts = []
        pillars = []
        accounts = []
        statusFilter = nil
        searchText = ""
        settings.isOn = false
    }

    /// Re-reads the queue. STUBBED -- a no-op against sample data.
    func refresh() async {
        guard connectionState == .connected else { return }
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: - Reading the queue

    /// The queue, newest-relevant first, after the status chip and the search
    /// field have both been applied.
    var visiblePosts: [ContentPost] {
        var result = posts

        if let statusFilter {
            result = result.filter { $0.status == statusFilter }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { post in
                post.hook.localizedCaseInsensitiveContains(query)
                    || post.caption.localizedCaseInsensitiveContains(query)
                    || post.script.localizedCaseInsensitiveContains(query)
                    || post.hashtags.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }

        return result.sorted { $0.effectiveDate > $1.effectiveDate }
    }

    /// Statuses actually present in the queue, in pipeline order. The chip row
    /// is built from this rather than from `PostStatus.allCases`, so it never
    /// offers a filter that would return nothing.
    var availableStatuses: [PostStatus] {
        let present = Set(posts.map(\.status))
        return PostStatus.allCases.filter { present.contains($0) }
    }

    var upcomingCount: Int {
        posts.filter { !$0.status.isTerminal }.count
    }

    /// What the person has to act on. Drives the badge on the queue tab.
    var awaitingApprovalCount: Int {
        guard settings.requiresApproval else { return 0 }
        return posts.filter(\.isAwaitingApproval).count
    }

    var nextScheduled: ContentPost? {
        posts
            .filter { $0.status == .scheduled }
            .sorted { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
            .first
    }

    func pillar(for post: ContentPost) -> ContentPillar? {
        guard let pillarID = post.pillarID else { return nil }
        return pillars.first { $0.id == pillarID }
    }

    // MARK: - Acting on a post

    func approve(_ post: ContentPost) {
        update(post.id) { existing in
            existing.approvedAt = Date()
            if existing.status == .planned || existing.status == .scripted {
                existing.status = .scheduled
            }
        }
    }

    /// Drops a post the autopilot planned. It does not come back, and the
    /// planner is told, so the same idea is not proposed again.
    func skip(_ post: ContentPost) {
        posts.removeAll { $0.id == post.id }
    }

    /// Publishes immediately, ignoring the schedule and the quiet window.
    ///
    /// STUBBED -- flips the status locally. The real version hands the rendered
    /// file to the platform's upload endpoint.
    func publishNow(_ post: ContentPost) async {
        guard connectionState == .connected else {
            lastError = "Connect an account before publishing."
            return
        }
        update(post.id) { existing in
            existing.status = .rendering
        }
        try? await Task.sleep(for: .milliseconds(500))
        update(post.id) { existing in
            existing.status = .posted
            existing.postedAt = Date()
            existing.approvedAt = existing.approvedAt ?? Date()
            existing.views = 0
            existing.likes = 0
        }
    }

    func setPillar(_ pillar: ContentPillar, enabled: Bool) {
        guard let index = pillars.firstIndex(where: { $0.id == pillar.id }) else { return }
        pillars[index].isEnabled = enabled
    }

    /// Applies `change` to the post with `id`, if it is still in the queue.
    /// Every mutation goes through here so there is one place that writes.
    private func update(_ id: UUID, _ change: (inout ContentPost) -> Void) {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        change(&posts[index])
    }
}
