import XCTest
@testable import ContentApp

/// The Profile's small pieces of logic: which privacy a post starts on, and
/// reading the usage numbers exactly as `usage_summary()` returns them.
final class ProfileTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: PostDefaults.privacyKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PostDefaults.privacyKey)
        super.tearDown()
    }

    func testPrivacyUsesTheDefaultWhenTheAccountOffersIt() {
        UserDefaults.standard.set("SELF_ONLY", forKey: PostDefaults.privacyKey)
        XCTAssertEqual(PostDefaults.privacy(from: ["PUBLIC_TO_EVERYONE", "SELF_ONLY"]), "SELF_ONLY")
    }

    func testPrivacyFallsBackWhenTheAccountDoesNotOfferTheDefault() {
        UserDefaults.standard.set("MUTUAL_FOLLOW_FRIENDS", forKey: PostDefaults.privacyKey)
        // An unaudited app is only offered private.
        XCTAssertEqual(PostDefaults.privacy(from: ["SELF_ONLY"]), "SELF_ONLY")
        XCTAssertEqual(PostDefaults.privacy(from: ["SELF_ONLY", "PUBLIC_TO_EVERYONE"]), "PUBLIC_TO_EVERYONE")
        XCTAssertNil(PostDefaults.privacy(from: []))
    }

    func testUsageDecodesTheServerShape() throws {
        let json = """
        {"posted":0,"by_kind":{"plan_write":6},"scheduled":0,"videos_made":8,"plans_written":2,
         "ai_generations":2,"sent_to_drafts":2,"recorded_cost_cents":0}
        """
        let usage = try JSONDecoder().decode(UsageSummary.self, from: Data(json.utf8))
        XCTAssertEqual(usage.sentToDrafts, 2)
        XCTAssertEqual(usage.videosMade, 8)
        XCTAssertEqual(usage.byKind["plan_write"], 6)
    }

    func testAppleNonceHashIsTheSHA256OfTheRawValue() {
        let nonce = AppSession.appleNonce()
        XCTAssertEqual(nonce.raw.count, 64)
        XCTAssertEqual(nonce.hashed.count, 64)
        XCTAssertNotEqual(nonce.raw, nonce.hashed)
    }
}
