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

    /// The brief the planner writes from -- who this account is for and what
    /// it has learned. Survives a disconnect, because it is the person's work,
    /// not the platform's data.
    var brand = BrandProfile()

    /// Delivered by the silent push the app already registers for. Both
    /// default on: an autopilot that publishes without telling you is a
    /// different product from one that publishes without asking you.
    var notifyOnPublish = true
    var notifyOnFailure = true

    /// True while `generate(days:)` is filling the schedule. Plan disables its
    /// generate menu on this so a double tap cannot queue two batches.
    private(set) var isGenerating = false

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
        if !brand.isComplete { brand = Self.sampleBrand }
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

    // MARK: - Making something on purpose

    /// Adds what the Create button asked for to the front of the queue.
    ///
    /// A requested post is still a `.planned` post: it goes through scripting,
    /// rendering and scheduling like everything else, and it still says on its
    /// row why it exists. The only difference is that the reason is "you asked",
    /// which is worth showing plainly rather than dressing up as a decision the
    /// autopilot made.
    @discardableResult
    func requestDraft(_ kind: CreateKind, brief: String = "", goal: CreateGoal = .reach) -> Bool {
        guard connectionState == .connected else {
            lastError = "Connect an account before creating."
            return false
        }

        let platform = settings.platforms.first ?? accounts.first?.platform ?? .tiktok
        let pillar = pillars.first(where: \.isEnabled)
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        let drafts = (0..<kind.postCount).map { index in
            ContentPost(
                hook: Self.workingTitle(from: trimmed, kind: kind, index: index),
                platform: platform,
                status: .planned,
                pillarID: pillar?.id,
                rationale: Self.requestedRationale(brief: trimmed, goal: goal),
                // Offset so two drafts requested in the same second still sort
                // in the order they were asked for.
                createdAt: now.addingTimeInterval(Double(index))
            )
        }

        posts.insert(contentsOf: drafts, at: 0)
        return true
    }

    /// A stand-in hook until the writer runs.
    ///
    /// The brief is the person's own words, so the first line of it is a far
    /// better placeholder than "New video" -- it makes the row recognisable in
    /// a queue before anything has actually been written.
    private static func workingTitle(from brief: String, kind: CreateKind, index: Int) -> String {
        let suffix = kind == .campaign ? " (\(index + 1) of \(kind.postCount))" : ""

        guard !brief.isEmpty else {
            return "New \(kind.displayName.lowercased())\(suffix)"
        }

        let firstLine = brief
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? brief

        let title = firstLine.count > 60
            ? firstLine.prefix(57).trimmingCharacters(in: .whitespaces) + "\u{2026}"
            : firstLine

        return title + suffix
    }

    /// Why a requested post exists, said plainly. It still carries a rationale
    /// like everything else in the queue -- the reason is just that you asked.
    private static func requestedRationale(brief: String, goal: CreateGoal) -> String {
        let opening = brief.isEmpty
            ? "You asked for this."
            : "You asked for this in your own words."
        return "\(opening) Written \(goal.briefPhrase)."
    }

    // MARK: - Planning ahead

    /// Fills the next `days` days at the configured rate.
    ///
    /// STUBBED -- picks slots and writes placeholder ideas. The real version
    /// asks the planner for `days * postsPerDay` ideas inside the enabled
    /// pillars and stores what comes back.
    func generate(days: Int) async {
        guard connectionState == .connected else {
            lastError = "Connect an account before generating."
            return
        }
        guard !isGenerating else { return }

        isGenerating = true
        defer { isGenerating = false }

        try? await Task.sleep(for: .milliseconds(600))

        let slots = plannableSlots(days: days, from: Date())
        guard !slots.isEmpty else {
            // Every candidate hour fell inside the quiet window, so there is
            // nowhere legal to put a post. Say that instead of silently
            // generating nothing.
            lastError = "Quiet hours cover the whole day, so there is no slot to post in."
            return
        }

        let platform = settings.platforms.first ?? accounts.first?.platform ?? .tiktok
        let enabled = pillars.filter(\.isEnabled)

        let planned = slots.enumerated().map { index, slot -> ContentPost in
            let pillar = enabled.isEmpty ? nil : enabled[index % enabled.count]
            return ContentPost(
                hook: pillar.map { "Idea from \($0.name.lowercased())" } ?? "Planned idea",
                platform: platform,
                status: .planned,
                pillarID: pillar?.id,
                rationale: pillar.map { "\($0.name) is due -- it has not run since the last batch." }
                    ?? "Filling an empty slot in the schedule.",
                scheduledFor: slot
            )
        }

        posts.append(contentsOf: planned)
    }

    /// Moves a post to a new time, refusing anything inside the quiet window.
    ///
    /// Returns false and sets `lastError` when the requested time is one the
    /// autopilot would refuse to publish in, so the caller can leave the row
    /// where it was rather than move it somewhere it will silently stall.
    @discardableResult
    func reschedule(_ post: ContentPost, to date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        guard !settings.isQuiet(hour: hour) else {
            lastError = "That time is inside your quiet hours."
            return false
        }
        guard !post.status.isTerminal else {
            lastError = "A post that has already gone out cannot be moved."
            return false
        }

        update(post.id) { existing in
            existing.scheduledFor = date
            if existing.status == .planned {
                existing.status = .scripted
            }
        }
        return true
    }

    /// Candidate publish times over the next `days` days, at `postsPerDay`
    /// each, skipping anything inside the quiet window or already in the past.
    private func plannableSlots(days: Int, from start: Date) -> [Date] {
        let calendar = Calendar.current
        // Spread across the day rather than clustering: a person scrolls at
        // different hours, and posting three in a row at 09:00 wastes two.
        let candidates = [9, 12, 15, 18, 20].filter { !settings.isQuiet(hour: $0) }
        guard !candidates.isEmpty else { return [] }

        var slots: [Date] = []
        for day in 0..<max(1, days) {
            guard let base = calendar.date(byAdding: .day, value: day, to: start) else { continue }
            for index in 0..<settings.postsPerDay {
                let hour = candidates[index % candidates.count]
                guard let slot = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base),
                      slot > start,
                      // Do not stack a second post onto a slot that is taken.
                      !posts.contains(where: { $0.scheduledFor == slot })
                else { continue }
                slots.append(slot)
            }
        }
        return slots.sorted()
    }

    // MARK: - Brand and memory

    /// Drops one thing the planner had worked out about the account.
    /// Destructive by design: the point of showing memory is being able to
    /// take something back out of it.
    func forget(_ item: String) {
        brand.memory.removeAll { $0 == item }
    }

    func forgetAllMemory() {
        brand.memory.removeAll()
    }

    /// Applies `change` to the post with `id`, if it is still in the queue.
    /// Every mutation goes through here so there is one place that writes.
    private func update(_ id: UUID, _ change: (inout ContentPost) -> Void) {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        change(&posts[index])
    }
}
