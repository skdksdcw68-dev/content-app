import XCTest
@testable import ContentApp

@MainActor
final class ContentStoreTests: XCTestCase {

    /// A connected store with sample data, which is the state almost every
    /// test wants.
    private func connectedStore() async -> ContentStore {
        let store = ContentStore()
        await store.connect()
        return store
    }

    // MARK: - Connection

    func testStartsDisconnectedAndEmpty() {
        let store = ContentStore()
        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertTrue(store.posts.isEmpty)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testConnectPopulatesQueueAndAccount() async {
        let store = await connectedStore()
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertFalse(store.posts.isEmpty)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.platform, .tiktok)
    }

    /// Connecting twice must not duplicate the queue -- the connect button can
    /// be tapped again while the first call is still settling.
    func testConnectIsIdempotent() async {
        let store = await connectedStore()
        let count = store.posts.count
        await store.connect()
        XCTAssertEqual(store.posts.count, count)
    }

    func testDisconnectClearsEverythingAndStopsAutopilot() async {
        let store = await connectedStore()
        store.settings.isOn = true
        store.statusFilter = .posted
        store.searchText = "mac"

        store.disconnect()

        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertTrue(store.posts.isEmpty)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.statusFilter)
        XCTAssertTrue(store.searchText.isEmpty)
        XCTAssertFalse(store.settings.isOn, "Autopilot must not stay armed with no account")
    }

    // MARK: - Filtering

    func testStatusFilterNarrowsToThatStatus() async {
        let store = await connectedStore()
        store.statusFilter = .scheduled
        XCTAssertFalse(store.visiblePosts.isEmpty)
        XCTAssertTrue(store.visiblePosts.allSatisfy { $0.status == .scheduled })
    }

    func testNilStatusFilterShowsEverything() async {
        let store = await connectedStore()
        store.statusFilter = nil
        XCTAssertEqual(store.visiblePosts.count, store.posts.count)
    }

    func testSearchMatchesHook() async {
        let store = await connectedStore()
        store.searchText = "without owning a Mac"
        XCTAssertEqual(store.visiblePosts.count, 1)
    }

    func testSearchMatchesHashtagAndIsCaseInsensitive() async {
        let store = await connectedStore()
        store.searchText = "#CICD"
        XCTAssertFalse(store.visiblePosts.isEmpty)
    }

    func testSearchAndStatusFilterCombine() async {
        let store = await connectedStore()
        store.statusFilter = .posted
        store.searchText = "sixty seconds"
        XCTAssertEqual(store.visiblePosts.count, 1)
    }

    func testWhitespaceOnlySearchIsIgnored() async {
        let store = await connectedStore()
        store.searchText = "   "
        XCTAssertEqual(store.visiblePosts.count, store.posts.count)
    }

    /// The chip row is built from this, so it must never offer a filter that
    /// would empty the list.
    func testAvailableStatusesArePresentAndInPipelineOrder() async {
        let store = await connectedStore()
        let present = Set(store.posts.map(\.status))
        XCTAssertEqual(Set(store.availableStatuses), present)
        XCTAssertEqual(
            store.availableStatuses,
            store.availableStatuses.sorted { $0.pipelineRank < $1.pipelineRank }
        )
    }

    func testVisiblePostsAreSortedNewestFirst() async {
        let store = await connectedStore()
        let dates = store.visiblePosts.map(\.effectiveDate)
        XCTAssertEqual(dates, dates.sorted(by: >))
    }

    // MARK: - Acting on a post

    func testApproveStampsApprovalAndSchedules() async {
        let store = await connectedStore()
        guard let planned = store.posts.first(where: { $0.status == .planned }) else {
            return XCTFail("sample data should contain a planned post")
        }
        store.approve(planned)

        let updated = store.posts.first { $0.id == planned.id }
        XCTAssertNotNil(updated?.approvedAt)
        XCTAssertEqual(updated?.status, .scheduled)
    }

    func testApproveDoesNotRewindAPostedPost() async {
        let store = await connectedStore()
        guard let posted = store.posts.first(where: { $0.status == .posted }) else {
            return XCTFail("sample data should contain a posted post")
        }
        store.approve(posted)
        XCTAssertEqual(store.posts.first { $0.id == posted.id }?.status, .posted)
    }

    func testSkipRemovesFromQueue() async {
        let store = await connectedStore()
        let target = store.posts[0]
        store.skip(target)
        XCTAssertFalse(store.posts.contains { $0.id == target.id })
    }

    func testPublishNowMarksPostedAndStampsTime() async {
        let store = await connectedStore()
        guard let pending = store.posts.first(where: { !$0.status.isTerminal }) else {
            return XCTFail("sample data should contain a pending post")
        }
        await store.publishNow(pending)

        let updated = store.posts.first { $0.id == pending.id }
        XCTAssertEqual(updated?.status, .posted)
        XCTAssertNotNil(updated?.postedAt)
        XCTAssertNotNil(updated?.approvedAt, "Publishing implies approval")
    }

    func testPublishNowRefusesWhenDisconnected() async {
        let store = ContentStore()
        let orphan = ContentPost(hook: "x", platform: .tiktok, status: .scheduled, rationale: "y")
        await store.publishNow(orphan)
        XCTAssertNotNil(store.lastError)
    }

    // MARK: - Counts the UI depends on

    func testAwaitingApprovalCountsOnlyUnapprovedScheduled() async {
        let store = await connectedStore()
        store.settings.requiresApproval = true
        let expected = store.posts.filter { $0.status == .scheduled && $0.approvedAt == nil }.count
        XCTAssertEqual(store.awaitingApprovalCount, expected)
    }

    /// With approval off the autopilot posts on its own, so there is nothing
    /// to review and the tab badge must disappear.
    func testAwaitingApprovalIsZeroWhenApprovalNotRequired() async {
        let store = await connectedStore()
        store.settings.requiresApproval = false
        XCTAssertEqual(store.awaitingApprovalCount, 0)
    }

    func testUpcomingCountExcludesPostedAndFailed() async {
        let store = await connectedStore()
        XCTAssertEqual(
            store.upcomingCount,
            store.posts.filter { !$0.status.isTerminal }.count
        )
        XCTAssertFalse(store.posts.filter { $0.status.isTerminal }.isEmpty)
    }

    func testNextScheduledIsTheEarliestScheduled() async {
        let store = await connectedStore()
        let earliest = store.posts
            .filter { $0.status == .scheduled }
            .compactMap(\.scheduledFor)
            .min()
        XCTAssertEqual(store.nextScheduled?.scheduledFor, earliest)
    }

    func testPillarLookupResolves() async {
        let store = await connectedStore()
        guard let post = store.posts.first(where: { $0.pillarID != nil }) else {
            return XCTFail("sample data should link posts to pillars")
        }
        XCTAssertNotNil(store.pillar(for: post))
    }

    // MARK: - Autopilot rules

    /// The normal case: the window wraps past midnight.
    func testQuietHoursWrappingMidnight() {
        let settings = AutopilotSettings(quietHoursStart: 22, quietHoursEnd: 7)
        XCTAssertTrue(settings.isQuiet(hour: 23))
        XCTAssertTrue(settings.isQuiet(hour: 3))
        XCTAssertTrue(settings.isQuiet(hour: 22))
        XCTAssertFalse(settings.isQuiet(hour: 7))
        XCTAssertFalse(settings.isQuiet(hour: 12))
    }

    func testQuietHoursWithinOneDay() {
        let settings = AutopilotSettings(quietHoursStart: 9, quietHoursEnd: 17)
        XCTAssertTrue(settings.isQuiet(hour: 12))
        XCTAssertFalse(settings.isQuiet(hour: 8))
        XCTAssertFalse(settings.isQuiet(hour: 17))
    }

    func testEqualQuietHoursMeansNoQuietWindow() {
        let settings = AutopilotSettings(quietHoursStart: 9, quietHoursEnd: 9)
        XCTAssertFalse(settings.isQuiet(hour: 9))
        XCTAssertFalse(settings.isQuiet(hour: 21))
    }

    func testSummaryReflectsWhetherItPostsAlone() {
        XCTAssertEqual(AutopilotSettings(isOn: false).summary, "Autopilot is off")

        let supervised = AutopilotSettings(isOn: true, postsPerDay: 2, requiresApproval: true)
        XCTAssertTrue(supervised.summary.contains("waits for your approval"))

        let autonomous = AutopilotSettings(isOn: true, postsPerDay: 1, requiresApproval: false)
        XCTAssertTrue(autonomous.summary.contains("posts on its own"))
        XCTAssertTrue(autonomous.summary.contains("1 post"), "Should not pluralise a single post")
    }

    // MARK: - Platform limits

    /// The failed sample post exists because a script ran over the limit. This
    /// is the check that would have caught it before the render was spent.
    func testScriptOverPlatformLimitIsFlagged() {
        let words = Array(repeating: "word", count: 200).joined(separator: " ")
        let post = ContentPost(hook: "h", script: words, platform: .shorts, status: .scripted, rationale: "r")
        XCTAssertGreaterThan(post.estimatedDuration, Platform.shorts.maxDuration)
        XCTAssertFalse(post.fitsPlatform)
    }

    func testShortScriptFitsEveryPlatform() {
        let post = ContentPost(hook: "h", script: "A very short script indeed.", platform: .shorts, status: .scripted, rationale: "r")
        XCTAssertTrue(post.fitsPlatform)
    }

    func testEffectiveDateFallsBackToCreation() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        let post = ContentPost(hook: "h", platform: .tiktok, status: .planned, rationale: "r", createdAt: created)
        XCTAssertEqual(post.effectiveDate, created)
    }
}
