import XCTest
@testable import ContentApp

/// What is left worth testing on the client.
///
/// The previous suite had 59 tests and roughly three quarters of them asserted
/// against a file of fixtures -- they proved the sample data was still the
/// sample data. Scheduling, quiet hours and pillar weighting have moved into SQL
/// where they are tested against a real Postgres. What remains here is the
/// contract between the app and the database, which is exactly where a rename
/// on one side and not the other would go unnoticed.
final class ModelTests: XCTestCase {

    // MARK: - The wire format

    /// These strings are the Postgres enum in migration 0002. A Swift-side
    /// rename that does not match is a decode failure at runtime, on a device,
    /// with no compiler warning anywhere.
    func testPostStatusRawValuesMatchTheDatabaseEnum() {
        XCTAssertEqual(PostStatus.planned.rawValue, "planned")
        XCTAssertEqual(PostStatus.scripted.rawValue, "scripted")
        XCTAssertEqual(PostStatus.sourcing.rawValue, "sourcing")
        XCTAssertEqual(PostStatus.needsApproval.rawValue, "needs_approval")
        XCTAssertEqual(PostStatus.scheduled.rawValue, "scheduled")
        XCTAssertEqual(PostStatus.posted.rawValue, "posted")
        XCTAssertEqual(PostStatus.failed.rawValue, "failed")
    }

    /// `pipelineRank` is declaration order, and the database orders by the same
    /// sequence. Reordering the cases silently reorders the pipeline.
    func testPipelineOrderIsTheDeclaredOrder() {
        XCTAssertEqual(
            PostStatus.allCases.map(\.pipelineRank),
            Array(0..<PostStatus.allCases.count)
        )
        XCTAssertLessThan(PostStatus.sourcing.pipelineRank, PostStatus.scheduled.pipelineRank)
        XCTAssertLessThan(PostStatus.needsApproval.pipelineRank, PostStatus.scheduled.pipelineRank)
    }

    func testOnlyPostedAndFailedAreTerminal() {
        let terminal = PostStatus.allCases.filter(\.isTerminal)
        XCTAssertEqual(Set(terminal), [.posted, .failed])
    }

    /// The one state a person can clear themselves.
    func testNeedsApprovalIsTheOnlyStateWaitingOnAPerson() {
        let waiting = PostStatus.allCases.filter(\.isWaitingOnYou)
        XCTAssertEqual(waiting, [.needsApproval])
    }

    func testPlatformRawValuesMatchTheDatabaseEnum() {
        XCTAssertEqual(Platform.tiktok.rawValue, "tiktok")
        XCTAssertEqual(Platform.reels.rawValue, "reels")
        XCTAssertEqual(Platform.shorts.rawValue, "shorts")
    }

    // MARK: - Decoding what the API actually sends

    func testBrandDecodesFromSnakeCasePayload() throws {
        let json = """
        {
          "id": "e7e3ecfb-b92b-458a-a8a0-5807f261bfb9",
          "name": "Remi",
          "audience": "",
          "niche": "an app",
          "timezone": "Africa/Addis_Ababa",
          "uses_memory": true
        }
        """.data(using: .utf8)!

        let brand = try JSONDecoder().decode(Brand.self, from: json)
        XCTAssertEqual(brand.name, "Remi")
        XCTAssertEqual(brand.timezone, "Africa/Addis_Ababa")
        XCTAssertTrue(brand.usesMemory)
        XCTAssertFalse(brand.isComplete, "audience is empty, so the brief is not complete")
    }

    func testConnectionDecodesAndHidesNoTokens() throws {
        let json = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "brand_id": "e7e3ecfb-b92b-458a-a8a0-5807f261bfb9",
          "platform": "tiktok",
          "username": "void_tgc",
          "display_name": "",
          "avatar_url": "https://example.com/a.jpg",
          "scopes": ["user.info.basic","video.publish"],
          "status": "active",
          "connected_at": "2026-09-06T11:45:33Z",
          "last_error": null
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let connection = try decoder.decode(PlatformConnection.self, from: json)

        XCTAssertEqual(connection.username, "void_tgc")
        XCTAssertTrue(connection.isHealthy)
        XCTAssertNil(connection.problem)
    }

    /// TikTok requires the creator be identifiable before every post, and real
    /// display names are routinely blank or a single invisible character -- the
    /// account this was first tested against has one. The handle is what gets
    /// shown for exactly that reason.
    func testLabelUsesTheHandleNotTheDisplayName() throws {
        let json = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "brand_id": "e7e3ecfb-b92b-458a-a8a0-5807f261bfb9",
          "platform": "tiktok",
          "username": "void_tgc",
          "display_name": "\u{FFF4}",
          "avatar_url": null,
          "scopes": [],
          "status": "active",
          "connected_at": "2026-09-06T11:45:33Z",
          "last_error": null
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let connection = try decoder.decode(PlatformConnection.self, from: json)

        XCTAssertEqual(connection.label, "@void_tgc")
    }

    func testUnhealthyConnectionExplainsItself() throws {
        for status in ["expired", "revoked", "error"] {
            let json = """
            {
              "id": "11111111-1111-4111-8111-111111111111",
              "brand_id": "e7e3ecfb-b92b-458a-a8a0-5807f261bfb9",
              "platform": "tiktok",
              "username": "void_tgc",
              "display_name": "",
              "avatar_url": null,
              "scopes": [],
              "status": "\(status)",
              "connected_at": "2026-09-06T11:45:33Z",
              "last_error": null
            }
            """.data(using: .utf8)!

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let connection = try decoder.decode(PlatformConnection.self, from: json)

            XCTAssertFalse(connection.isHealthy)
            XCTAssertNotNil(connection.problem, "\(status) must explain itself to the person")
        }
    }

    // MARK: - The plan

    /// The bug this exists to stop: PostgREST prints a `timestamptz` without
    /// fractional seconds when the value has none, and `scheduled_for` always
    /// lands exactly on the hour. A single ISO8601 formatter parses
    /// `created_at` happily and returns nil for every slot in the plan, so the
    /// month renders with "--:--" against every line and nothing crashes.
    func testTimestampsParseWithAndWithoutFractionalSeconds() {
        let withFraction = PostgresTimestamp.parse("2026-09-07T06:48:12.49304+00:00")
        XCTAssertNotNil(withFraction, "created_at carries fractional seconds")

        let plain = PostgresTimestamp.parse("2026-09-08T06:00:00+00:00")
        XCTAssertNotNil(plain, "scheduled_for lands on the hour and carries none")

        XCTAssertEqual(
            plain?.timeIntervalSince1970,
            Date(timeIntervalSince1970: 1_788_847_200).timeIntervalSince1970,
            "08 Sep 2026 06:00 UTC"
        )

        XCTAssertNil(PostgresTimestamp.parse("tomorrow morning"))
    }

    /// The shape `refreshPlan()` actually asks PostgREST for, including the
    /// embedded theme. A rename on either side lands here rather than on a
    /// device.
    func testPlannedPostDecodesTheRowTheAppSelects() throws {
        let json = """
        {
          "id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
          "day_index": 4,
          "slot_index": 0,
          "hook": "I removed a step that was slowing new people down.",
          "script": "Onboarding got shorter this week.",
          "concept": "Screen recording of the old flow beside the new one.",
          "rationale": "It shows the work rather than claiming it.",
          "status": "planned",
          "scheduled_for": "2026-09-11T06:00:00+00:00",
          "content_pillars": { "name": "Behind the build" }
        }
        """.data(using: .utf8)!

        let post = try JSONDecoder().decode(PlannedPost.self, from: json)

        XCTAssertEqual(post.dayIndex, 4)
        XCTAssertEqual(post.status, .planned)
        XCTAssertEqual(post.pillar?.name, "Behind the build")
        XCTAssertNotNil(post.scheduledFor)
    }

    /// A post with no theme is normal -- an account with no pillars gets a null
    /// `pillar_id` from allocate_slots -- and must not fail the whole decode.
    func testPlannedPostSurvivesAMissingTheme() throws {
        let json = """
        {
          "id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
          "day_index": null,
          "slot_index": 0,
          "hook": "A hook",
          "script": "",
          "concept": "",
          "rationale": "Because.",
          "status": "scheduled",
          "scheduled_for": null,
          "content_pillars": null
        }
        """.data(using: .utf8)!

        let post = try JSONDecoder().decode(PlannedPost.self, from: json)

        XCTAssertNil(post.pillar)
        XCTAssertNil(post.dayIndex)
        XCTAssertNil(post.scheduledFor)
        XCTAssertEqual(post.status, .scheduled)
    }

    /// `proposed` is waiting on a person and `active` is running. The two drive
    /// completely different screens, and getting them the wrong way round would
    /// offer an Approve button for a plan that is already publishing.
    func testPlanStatusSeparatesWaitingFromRunning() throws {
        func plan(_ status: String) throws -> ContentPlan {
            let json = """
            {
              "id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
              "title": "Launch week",
              "status": "\(status)",
              "starts_on": "2026-09-07",
              "days": 30,
              "posts_per_day": 1,
              "brief": "",
              "approved_at": null
            }
            """.data(using: .utf8)!
            return try JSONDecoder().decode(ContentPlan.self, from: json)
        }

        XCTAssertTrue(try plan("proposed").isProposal)
        XCTAssertFalse(try plan("proposed").isRunning)
        XCTAssertTrue(try plan("active").isRunning)
        XCTAssertFalse(try plan("active").isProposal)

        // A date, kept as one. Parsing it would attach a midnight and a zone the
        // value does not have.
        XCTAssertEqual(try plan("proposed").startsOn, "2026-09-07")
    }

    /// Asking for thirty days can produce fewer posts -- today's slot may have
    /// passed, and a batch can come back short. Both numbers are carried so the
    /// app can say so rather than quietly showing 28 where 30 was asked for.
    func testProposalReportsWhatItActuallyWrote() throws {
        let json = """
        {
          "plan_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
          "title": "Launch week",
          "starts_on": "2026-09-07",
          "days": 30,
          "posts_per_day": 1,
          "planned": 28,
          "dropped": 1,
          "slots": 29
        }
        """.data(using: .utf8)!

        let proposal = try JSONDecoder().decode(PlanProposal.self, from: json)

        XCTAssertEqual(proposal.days, 30, "what was asked for")
        XCTAssertEqual(proposal.slots, 29, "today's slot had already passed")
        XCTAssertEqual(proposal.planned, 28, "one came back without a rationale")
        XCTAssertEqual(proposal.dropped, 1)
    }
}
