import XCTest
@testable import ContentApp

/// Covers everything the four-tab navigation added: asking for a post by hand,
/// filling the schedule, moving a post, and the numbers Home and Insights read.
@MainActor
final class PlanningTests: XCTestCase {

    private func connectedStore() async -> ContentStore {
        let store = ContentStore()
        await store.connect()
        return store
    }

    // MARK: - Create

    func testRequestDraftAddsOnePlannedPost() async {
        let store = await connectedStore()
        let before = store.posts.count

        store.requestDraft(.video)

        XCTAssertEqual(store.posts.count, before + 1)
        XCTAssertEqual(store.posts.first?.status, .planned)
        XCTAssertNil(store.lastError)
    }

    /// A campaign is the only kind that is more than one post, and the count
    /// has to match what the menu row promises.
    func testRequestCampaignAddsItsWholeRun() async {
        let store = await connectedStore()
        let before = store.posts.count

        store.requestDraft(.campaign)

        XCTAssertEqual(store.posts.count, before + CreateKind.campaign.postCount)
    }

    /// A requested post still has to say why it exists, like every other row.
    func testRequestedDraftCarriesARationale() async {
        let store = await connectedStore()
        store.requestDraft(.post)
        XCTAssertFalse(store.posts.first?.rationale.isEmpty ?? true)
    }

    /// The brief is the person's own words, so it makes a far better working
    /// title than "New video" while the writer has not run yet.
    func testBriefBecomesTheWorkingTitle() async {
        let store = await connectedStore()
        store.requestDraft(.video, brief: "The two-certificate limit nobody mentions")

        XCTAssertEqual(store.posts.first?.hook, "The two-certificate limit nobody mentions")
    }

    func testEmptyBriefFallsBackToTheFormatName() async {
        let store = await connectedStore()
        store.requestDraft(.video, brief: "   ")

        XCTAssertEqual(store.posts.first?.hook, "New video")
    }

    /// A working title has to fit on a row, so a long brief is cut rather than
    /// wrapped to three lines in every list in the app.
    func testLongBriefIsTruncated() async {
        let store = await connectedStore()
        let long = String(repeating: "signing ", count: 40)
        store.requestDraft(.video, brief: long)

        let hook = store.posts.first?.hook ?? ""
        XCTAssertLessThanOrEqual(hook.count, 61)
        XCTAssertTrue(hook.hasSuffix("\u{2026}"))
    }

    /// Only the first line becomes the title, so pasting several paragraphs
    /// does not put a paragraph on the row.
    func testOnlyTheFirstLineOfABriefIsUsed() async {
        let store = await connectedStore()
        store.requestDraft(.video, brief: "Certificates\nEverything after this is detail.")

        XCTAssertEqual(store.posts.first?.hook, "Certificates")
    }

    /// The goal changes the writing, so it has to be visible on the row rather
    /// than vanishing into a field nobody sees again.
    func testGoalIsRecordedInTheRationale() async {
        let store = await connectedStore()
        store.requestDraft(.video, brief: "anything", goal: .saves)

        let rationale = store.posts.first?.rationale ?? ""
        XCTAssertTrue(
            rationale.contains(CreateGoal.saves.briefPhrase),
            "Expected the goal in the rationale, got: \(rationale)"
        )
    }

    func testCampaignPostsAreNumbered() async {
        let store = await connectedStore()
        store.requestDraft(.campaign, brief: "Launch week")

        let campaign = store.posts.prefix(CreateKind.campaign.postCount)
        XCTAssertTrue(campaign.allSatisfy { $0.hook.contains("Launch week") })
        XCTAssertTrue(campaign.contains { $0.hook.contains("1 of 4") })
        XCTAssertTrue(campaign.contains { $0.hook.contains("4 of 4") })
    }

    func testRequestDraftRefusesWhenDisconnected() {
        let store = ContentStore()
        store.requestDraft(.video)

        XCTAssertTrue(store.posts.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    // MARK: - Generate

    func testGenerateFillsTheRequestedWindow() async {
        let store = await connectedStore()
        let before = store.posts.count

        await store.generate(days: 7)

        XCTAssertGreaterThan(store.posts.count, before)
        XCTAssertFalse(store.isGenerating, "The flag has to clear or the menu stays disabled")
    }

    /// Nothing may be scheduled inside the quiet window, because a post parked
    /// there never goes out and the queue silently stalls.
    func testGenerateNeverSchedulesInsideQuietHours() async {
        let store = await connectedStore()
        store.settings.quietHoursStart = 22
        store.settings.quietHoursEnd = 7

        await store.generate(days: 14)

        let calendar = Calendar.current
        for post in store.posts {
            guard let slot = post.scheduledFor, post.status == .planned else { continue }
            let hour = calendar.component(.hour, from: slot)
            XCTAssertFalse(
                store.settings.isQuiet(hour: hour),
                "Generated a slot at \(hour):00, inside quiet hours"
            )
        }
    }

    /// Quiet hours covering the entire day leaves nowhere legal to post. That
    /// has to be said out loud rather than generating nothing in silence.
    func testGenerateReportsWhenQuietHoursLeaveNoSlot() async {
        let store = await connectedStore()
        // start == end is treated as no quiet hours at all, so the window that
        // actually covers every candidate hour is 01:00 round to 00:00.
        store.settings.quietHoursStart = 1
        store.settings.quietHoursEnd = 0

        await store.generate(days: 3)

        XCTAssertNotNil(store.lastError)
    }

    func testGenerateRefusesWhenDisconnected() async {
        let store = ContentStore()
        await store.generate(days: 7)

        XCTAssertTrue(store.posts.isEmpty)
        XCTAssertNotNil(store.lastError)
    }

    // MARK: - Rescheduling

    func testRescheduleMovesAPostAndReportsSuccess() async {
        let store = await connectedStore()
        guard let post = store.posts.first(where: { $0.status == .scheduled }),
              let current = post.scheduledFor else {
            return XCTFail("sample data should contain a scheduled post")
        }

        // 12:00 tomorrow is outside the default quiet window either way.
        let target = Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0,
            of: current.addingTimeInterval(86_400)
        ) ?? current

        XCTAssertTrue(store.reschedule(post, to: target))
        XCTAssertEqual(store.posts.first { $0.id == post.id }?.scheduledFor, target)
    }

    func testRescheduleRefusesQuietHours() async {
        let store = await connectedStore()
        store.settings.quietHoursStart = 22
        store.settings.quietHoursEnd = 7

        guard let post = store.posts.first(where: { $0.status == .scheduled }),
              let current = post.scheduledFor else {
            return XCTFail("sample data should contain a scheduled post")
        }

        let intoQuiet = Calendar.current.date(
            bySettingHour: 23, minute: 0, second: 0, of: current
        ) ?? current

        XCTAssertFalse(store.reschedule(post, to: intoQuiet))
        XCTAssertEqual(
            store.posts.first { $0.id == post.id }?.scheduledFor,
            current,
            "A refused move must leave the post where it was"
        )
        XCTAssertNotNil(store.lastError)
    }

    func testReschedulePostedPostIsRefused() async {
        let store = await connectedStore()
        guard let posted = store.posts.first(where: { $0.status == .posted }) else {
            return XCTFail("sample data should contain a posted post")
        }

        // Pinned to midday so this fails on the terminal-status guard rather
        // than tripping the quiet-hours guard when the suite runs at night.
        let target = Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0,
            of: Date().addingTimeInterval(86_400)
        ) ?? Date()

        XCTAssertFalse(store.reschedule(posted, to: target))
        XCTAssertEqual(store.lastError, "A post that has already gone out cannot be moved.")
    }

    // MARK: - Numbers the screens read

    /// A metric nothing reported must come back nil, not zero -- the tiles
    /// render those two cases differently on purpose.
    func testTotalsAreNilWithNothingPublished() {
        let store = ContentStore()
        XCTAssertNil(store.totalViews)
        XCTAssertNil(store.totalSaves)
        XCTAssertNil(store.averageEngagement)
        XCTAssertEqual(store.publishedCount, 0)
    }

    func testTotalsSumOnlyPublishedPosts() async {
        let store = await connectedStore()
        let expected = store.posts
            .filter { $0.status == .posted }
            .compactMap(\.views)
            .reduce(0, +)

        XCTAssertEqual(store.totalViews, expected)
    }

    func testTopTopicsAreRankedByViews() async {
        let store = await connectedStore()
        let views = store.topTopics.map(\.views)
        XCTAssertEqual(views, views.sorted(by: >))
        XCTAssertFalse(store.topTopics.isEmpty, "sample data should link posted work to pillars")
    }

    func testBestHooksAreRankedByViews() async {
        let store = await connectedStore()
        let views = store.bestHooks.compactMap(\.views)
        XCTAssertEqual(views, views.sorted(by: >))
    }

    /// Only hours that have actually been posted in may be recommended.
    func testBestHoursOnlyCoverHoursActuallyUsed() async {
        let store = await connectedStore()
        let calendar = Calendar.current
        let used = Set(store.posts.compactMap { post -> Int? in
            guard post.status == .posted, let at = post.postedAt else { return nil }
            return calendar.component(.hour, from: at)
        })

        XCTAssertEqual(Set(store.bestHours.map(\.hour)), used)
    }

    func testEngagementRateIsNilWithoutViews() {
        let post = ContentPost(hook: "x", platform: .tiktok, status: .planned, rationale: "y")
        XCTAssertNil(post.engagementRate)
    }

    func testEngagementRateCountsEveryInteraction() {
        let post = ContentPost(
            hook: "x",
            platform: .tiktok,
            status: .posted,
            rationale: "y",
            views: 1_000,
            likes: 50,
            saves: 30,
            shares: 20
        )
        XCTAssertEqual(post.engagementRate ?? 0, 0.1, accuracy: 0.0001)
    }

    // MARK: - Home

    /// A failure outranks everything else, because it is the only state that
    /// will not resolve itself.
    func testHomeInsightLeadsWithAFailure() async {
        let store = await connectedStore()
        XCTAssertEqual(store.homeInsight.id, "failed")
    }

    func testHomeInsightFallsBackToApprovalsOnceNothingHasFailed() async {
        let store = await connectedStore()
        for post in store.posts where post.status == .failed {
            store.skip(post)
        }
        store.settings.requiresApproval = true

        XCTAssertEqual(store.homeInsight.id, "approval")
    }

    func testTodayCompletionIsNilWhenNothingIsDueToday() {
        let store = ContentStore()
        XCTAssertNil(store.todayCompletion)
    }

    // MARK: - Memory

    func testForgetRemovesOneMemory() async {
        let store = await connectedStore()
        guard let first = store.brand.memory.first else {
            return XCTFail("sample brand should carry memory")
        }
        let before = store.brand.memory.count

        store.forget(first)

        XCTAssertEqual(store.brand.memory.count, before - 1)
        XCTAssertFalse(store.brand.memory.contains(first))
    }

    func testForgetAllClearsMemoryButKeepsTheBrief() async {
        let store = await connectedStore()
        store.forgetAllMemory()

        XCTAssertTrue(store.brand.memory.isEmpty)
        XCTAssertTrue(store.brand.isComplete, "Clearing memory must not clear the brief")
    }

    /// Disconnecting clears the account and the queue. The brief is the
    /// person's own work and has to survive it.
    func testBrandSurvivesDisconnect() async {
        let store = await connectedStore()
        let brand = store.brand

        store.disconnect()

        XCTAssertEqual(store.brand, brand)
    }
}
