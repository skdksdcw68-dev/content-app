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
}
