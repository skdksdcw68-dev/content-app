import XCTest
@testable import ContentApp

/// The usage meter, and the three plans it is spent in (29 Sep 2026, migration
/// 0077; in % since 18 Oct 2026, migration 0079).
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

    /// Netro, 2 Oct 2026: Ultra is monthly only. Its button must never be left
    /// with a yearly product that does not exist.
    func testUltraIsSoldMonthlyOnly() {
        XCTAssertTrue(Tier.pro.sellsYearly)
        XCTAssertTrue(Tier.max.sellsYearly)
        XCTAssertFalse(Tier.ultra.sellsYearly)
    }

    func testCreditsAreReadWithSeparators() {
        XCTAssertEqual(CreditFormat.text(2600), "2,600")
        XCTAssertEqual(CreditFormat.text(7_000), "7,000")
        XCTAssertEqual(CreditFormat.text(35), "35")
    }

    /// Netro, 18 Oct 2026: "count with % like claude and chatgpt". A share is
    /// read the way people read one -- never "0%" for something that costs.
    func testASharesReadsLikeAUsageMeter() {
        XCTAssertEqual(UsageFormat.percent(0), "0%")
        XCTAssertEqual(UsageFormat.percent(0.01), "under 1%", "a chat reply")
        XCTAssertEqual(UsageFormat.percent(4.4), "4%")
        XCTAssertEqual(UsageFormat.percent(62.5), "63%")
        XCTAssertEqual(UsageFormat.short(0.3), "<1%")
        XCTAssertEqual(UsageFormat.short(12), "12%")
    }

    /// Max is 3x Pro and Ultra 8x, as 0079 sets the budgets ($8, $24, $64).
    func testTheFallbackUsageMatchesTheServer() {
        XCTAssertEqual(Tier.pro.fallbackUsage, 1)
        XCTAssertEqual(Tier.max.fallbackUsage, 3)
        XCTAssertEqual(Tier.ultra.fallbackUsage, 8)
        XCTAssertEqual(Tier.max.fallbackBudgetUSD / Tier.pro.fallbackBudgetUSD, Tier.max.fallbackUsage)
        XCTAssertEqual(Tier.ultra.fallbackBudgetUSD / Tier.pro.fallbackBudgetUSD, Tier.ultra.fallbackUsage)
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
         "limits":{"ai_writes":1500,"chat":2000,"plan_days":60,"accounts":10,"credits":2600},
         "used":{"ai_writes":1,"chat":2,"credits":0}}
        """#
        let plan = try JSONDecoder().decode(MyPlan.self, from: Data(new.utf8))
        XCTAssertEqual(plan.tier, 2)
        XCTAssertEqual(plan.title, "Max")
    }

    func testTheCreditsStandingReadsAndReportsWhatIsLeft() throws {
        let json = #"""
        {"plan":"creator","name":"Pro","tier":1,"allowance":800,"used":200,"left":600,
         "resets_at":"2026-10-01T00:00:00+00:00"}
        """#
        let standing = try JSONDecoder().decode(CreditsStanding.self, from: Data(json.utf8))
        XCTAssertEqual(standing.left, 600)
        XCTAssertEqual(standing.fractionLeft, 0.75, accuracy: 0.0001)
    }

    func testAnEmptyAllowanceHasNothingLeftRatherThanDividingByZero() throws {
        let json = #"{"plan":"free","name":"Free","tier":0,"allowance":0,"used":0,"left":0,"resets_at":null}"#
        let standing = try JSONDecoder().decode(CreditsStanding.self, from: Data(json.utf8))
        XCTAssertEqual(standing.fractionLeft, 0)
        XCTAssertEqual(standing.percentLeft, 0)
    }

    /// 0079's reply: the server's own % wins over the counts.
    func testTheMeterReadsTheServersPercent() throws {
        let json = #"""
        {"plan":"creator","name":"Pro","tier":1,"allowance":80000,"used":20000,"left":60000,
         "percent_used":25.0,"budget_usd":8.0,"unit_usd":0.0001,"resets_at":"2026-11-16T04:45:15+00:00"}
        """#
        let standing = try JSONDecoder().decode(CreditsStanding.self, from: Data(json.utf8))
        XCTAssertEqual(standing.percentUsed, 25, accuracy: 0.001)
        XCTAssertEqual(standing.percentLeft, 75, accuracy: 0.001)
        XCTAssertEqual(standing.budgetUSD, 8)
    }

    // MARK: - The price the send button shows

    /// The phone and the server count the same units ($0.0001, 0079), and the
    /// adapter hands over prices in whole cents, so the two can never split.
    func testAMeterUnitIsAHundredthOfACent() {
        func cost(_ dollars: Double) -> ModelCost {
            ModelCost(unit: "usd", amount: dollars, basis: nil, quoted: false)
        }
        XCTAssertEqual(cost(0.35).credits, 3_500, "a five-second Kling clip")
        XCTAssertEqual(cost(0.01).credits, 100)
        XCTAssertEqual(cost(0.00004).credits, 1, "never rounds to nothing")
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
        XCTAssertEqual(plain.minimumTier(isVideo: false), 1, "nothing is free to make (2 Oct 2026)")

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

    func testASeriesClipIsEstimatedAtTheDefaultModelsRateUpToTenSeconds() {
        XCTAssertEqual(SeriesCost.perVideoUSD(seconds: 5), 0.35, accuracy: 0.0001)
        XCTAssertEqual(SeriesCost.perVideoUSD(seconds: 30), 0.70, accuracy: 0.0001, "clips stop at about ten seconds")
        XCTAssertEqual(SeriesCost.perVideoUSD(seconds: nil), 0.35, accuracy: 0.0001)
    }
}
