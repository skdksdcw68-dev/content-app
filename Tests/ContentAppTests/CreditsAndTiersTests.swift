import XCTest
@testable import ContentApp

/// Credits, and the three plans they are spent in (29 Sep 2026, migration 0077).
///
/// Every one of these is a way the money side could be wrong without anything
/// crashing: a product id typed one letter off is a paywall that sells nothing,
/// a price that rounds differently on the phone and the server is a send button
/// that says one number and takes another, and a plan reply an older server
/// sends without the new fields must not stop the app reading who is Pro.
final class CreditsAndTiersTests: XCTestCase {

    // MARK: - The plans

    /// Pro's two products already exist in App Store Connect under these exact
    /// ids. The new tiers follow the same pattern; getting either wrong sells
    /// nothing.
    func testProductIdsFollowTheOnesAlreadyInAppStoreConnect() {
        XCTAssertEqual(Tier.pro.productID(yearly: false), "autocast.pro.monthly")
        XCTAssertEqual(Tier.pro.productID(yearly: true), "autocast.pro.yearly")
        XCTAssertEqual(Tier.max.productID(yearly: false), "autocast.max.monthly")
        XCTAssertEqual(Tier.ultra.productID(yearly: true), "autocast.ultra.yearly")
        XCTAssertEqual(Tier.allProductIDs.count, 6)
        XCTAssertEqual(Set(Tier.allProductIDs).count, 6)
    }

    func testAProductBelongsToItsTier() {
        XCTAssertEqual(Tier.of(productID: "autocast.max.yearly"), .max)
        XCTAssertEqual(Tier.of(productID: "autocast.pro.monthly"), .pro)
        XCTAssertNil(Tier.of(productID: "something.else"))
    }

    /// The server calls Pro `creator` and always has; ranks match
    /// `plans_catalog.tier`.
    func testPlanCodesAndRanksMatchTheServer() {
        XCTAssertEqual(Tier.pro.planCode, "creator")
        XCTAssertEqual(Tier.max.planCode, "max")
        XCTAssertEqual(Tier.ultra.planCode, "ultra")
        XCTAssertEqual(Tier.allCases.map(\.rank), [1, 2, 3])
        XCTAssertEqual(Tier.of(planCode: "creator"), .pro)
        XCTAssertNil(Tier.of(planCode: "free"))
    }

    func testTheMiddleTierIsTheOneRecommended() {
        XCTAssertEqual(Tier.recommended, .max)
    }

    func testCreditsAreReadWithSeparators() {
        XCTAssertEqual(CreditFormat.text(8000), "8,000")
        XCTAssertEqual(CreditFormat.text(70_000), "70,000")
        XCTAssertEqual(CreditFormat.text(350), "350")
    }

    // MARK: - What a plan reply looks like

    /// An older server does not send `name` or `tier`. Reading who is Pro must
    /// not depend on them.
    func testAPlanReplyFromBeforeTheTiersStillReads() throws {
        let old = #"""
        {"plan":"creator","is_pro":true,"is_trial":false,"product_id":"autocast.pro.monthly",
         "expires_at":null,"auto_renew":true,
         "limits":{"ai_writes":500,"chat":1000,"plan_days":30,"accounts":5},
         "used":{"ai_writes":1,"chat":2}}
        """#
        let plan = try JSONDecoder().decode(MyPlan.self, from: Data(old.utf8))
        XCTAssertTrue(plan.isPro)
        XCTAssertNil(plan.tier)
        XCTAssertEqual(plan.title, "Pro")
    }

    func testAPlanReplyWithTheTiersNamesThePlan() throws {
        let new = #"""
        {"plan":"max","name":"Max","tier":2,"is_pro":true,"is_trial":false,"product_id":"autocast.max.yearly",
         "expires_at":null,"auto_renew":true,
         "limits":{"ai_writes":1500,"chat":3000,"plan_days":60,"accounts":10,"credits":26000},
         "used":{"ai_writes":1,"chat":2,"credits":0}}
        """#
        let plan = try JSONDecoder().decode(MyPlan.self, from: Data(new.utf8))
        XCTAssertEqual(plan.tier, 2)
        XCTAssertEqual(plan.title, "Max")
    }

    func testTheCreditsStandingReadsAndReportsWhatIsLeft() throws {
        let json = #"""
        {"plan":"creator","name":"Pro","tier":1,"allowance":8000,"used":2000,"left":6000,
         "resets_at":"2026-10-01T00:00:00+00:00"}
        """#
        let standing = try JSONDecoder().decode(CreditsStanding.self, from: Data(json.utf8))
        XCTAssertEqual(standing.left, 6000)
        XCTAssertEqual(standing.fractionLeft, 0.75, accuracy: 0.0001)
    }

    func testAnEmptyAllowanceHasNothingLeftRatherThanDividingByZero() throws {
        let json = #"{"plan":"free","name":"Free","tier":0,"allowance":0,"used":0,"left":0,"resets_at":null}"#
        let standing = try JSONDecoder().decode(CreditsStanding.self, from: Data(json.utf8))
        XCTAssertEqual(standing.fractionLeft, 0)
    }

    // MARK: - The price the send button shows

    /// The phone and the server round the same way, so the number on the button
    /// is the number taken. `GenerateChoices.credits` is what the send button
    /// used from the start; the server's `creditsFor` matches it.
    func testACreditIsATenthOfACent() {
        func cost(_ dollars: Double) -> ModelCost {
            ModelCost(unit: "usd", amount: dollars, basis: nil, quoted: false)
        }
        XCTAssertEqual(cost(0.35).credits, 350)
        XCTAssertEqual(cost(0.003).credits, 3)
        XCTAssertEqual(cost(0.0398).credits, 40)
        XCTAssertEqual(cost(0.0004).credits, 1, "never rounds to nothing")
        XCTAssertEqual(cost(3.2).credits, 3200)
    }

    func testAPriceNotInDollarsIsNotACreditCount() {
        let perSecond = ModelCost(unit: "per_second", amount: 0.05, basis: nil, quoted: false)
        XCTAssertNil(perSecond.credits)
        let unknown = ModelCost(unit: "usd", amount: nil, basis: nil, quoted: false)
        XCTAssertNil(unknown.credits)
    }

    // MARK: - Which model needs which plan

    private func model(_ constraints: String) throws -> ModelChoice {
        let decoded = try JSONDecoder().decode(ModelConstraints.self, from: Data(constraints.utf8))
        return ModelChoice(
            modelId: "m", provider: "fal", label: "m", externalId: "m",
            cost: ModelCost(unit: "usd", amount: 0.1, basis: nil, quoted: false),
            constraints: decoded, reason: nil, recommended: false, affordable: nil,
            badges: nil, family: nil, about: nil, suitable: true
        )
    }

    /// Video is a paid feature at all; a model's own `minTier` raises it.
    func testVideoNeedsAPaidPlanAndAPremiumModelNeedsMore() throws {
        let plain = try model(#"{"audio":true}"#)
        XCTAssertEqual(plain.minimumTier(isVideo: true), 1)
        XCTAssertEqual(plain.unlockedBy(isVideo: true), "Pro")
        XCTAssertEqual(plain.minimumTier(isVideo: false), 0, "a cheap picture is free")

        let premium = try model(#"{"audio":true,"minTier":2}"#)
        XCTAssertEqual(premium.minimumTier(isVideo: true), 2)
        XCTAssertEqual(premium.unlockedBy(isVideo: true), "Max")
    }

    // MARK: - Sound that cannot be switched

    /// MiniMax H3's sound is always there. There is nothing to switch, so no
    /// button -- and the line for a voice to speak still applies.
    func testASoundThatCannotBeSwitchedHasNoButtonButCanStillSpeak() throws {
        var choices = GenerateChoices()
        choices.model = try model(#"{"audio":true,"audioSwitch":false,"durations":[5,10]}"#)
        XCTAssertFalse(choices.hasSound, "no sound button")
        XCTAssertTrue(choices.makesSound)
        XCTAssertTrue(choices.canSpeak)
        XCTAssertNil(choices.settings.extras["generate_audio"], "nothing to send")
    }

    // MARK: - What a series is expected to cost

    func testASeriesClipIsEstimatedAtAboutEightyCreditsASecondUpToTen() {
        XCTAssertEqual(SeriesCost.perVideo(seconds: 5), 400)
        XCTAssertEqual(SeriesCost.perVideo(seconds: 30), 800, "clips stop at about ten seconds")
        XCTAssertEqual(SeriesCost.perVideo(seconds: nil), 400)
    }
}
