import Foundation
import Supabase

/// This month's usage, from `credits_standing()` (0077, reshaped by 0079).
///
/// Netro, 18 Oct 2026: count it in % "like claude and chatgpt usage", with
/// OpenAI and fal both drawing on the same 100. So the month is a meter: chat,
/// plans and captions take a sliver of it, pictures and videos more, and what
/// a thing will take is shown before it is made. The server keeps the meter in
/// small units; nothing on screen ever shows one.
struct CreditsStanding: Decodable, Equatable, Sendable {
    let plan: String
    let name: String?
    /// 0 free, 1 Pro, 2 Max, 3 Ultra.
    let tier: Int
    let allowance: Int
    let used: Int
    let left: Int
    let resetsAt: String?
    /// How much of the month is gone, 0 to 100. Absent from a server older
    /// than 0079; worked out from the counts then.
    let percentUsedValue: Double?
    /// The month's budget in rate-card dollars, which a price is a share of.
    let budgetUSD: Double?

    enum CodingKeys: String, CodingKey {
        case plan, name, tier, allowance, used, left
        case resetsAt = "resets_at"
        case percentUsedValue = "percent_used"
        case budgetUSD = "budget_usd"
    }

    var resets: Date? { resetsAt.flatMap(PostgresTimestamp.parse) }

    /// How much of the month is still there, 0 to 1.
    var fractionLeft: Double {
        guard allowance > 0 else { return 0 }
        return min(1, max(0, Double(left) / Double(allowance)))
    }

    /// How much of the month is gone, 0 to 100.
    var percentUsed: Double {
        if let percentUsedValue { return min(100, max(0, percentUsedValue)) }
        return 100 * (1 - fractionLeft)
    }

    /// How much is left, 0 to 100.
    var percentLeft: Double { 100 - percentUsed }
}

/// One paid tier, from `plan_tiers()`: what it gives, as the server enforces it.
struct PlanTierInfo: Decodable, Equatable, Sendable, Identifiable {
    let code: String
    let name: String
    let tier: Int
    let credits: Int
    /// How much it gives next to Pro: 1, 3, 8. Absent before 0079.
    let usage: Double?
    let budgetUSD: Double?
    let chat: Int
    let planDays: Int
    let accounts: Int

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code, name, tier, credits, usage, chat, accounts
        case budgetUSD = "budget_usd"
        case planDays = "plan_days"
    }
}

/// A share of the month the way people read one: "under 1%", "4%", "100%".
enum UsageFormat {
    static func percent(_ share: Double) -> String {
        if share <= 0 { return "0%" }
        if share < 1 { return "under 1%" }
        return "\(Int(share.rounded()))%"
    }

    /// The compact form for a button: "<1%", "4%".
    static func short(_ share: Double) -> String {
        if share > 0 && share < 1 { return "<1%" }
        return "\(Int(share.rounded()))%"
    }
}

/// What a video in a series is expected to cost, for the sentence that says
/// how much of a month a series draws on. An estimate, said as one: the real
/// price is the model's, at the length asked, and is shown before anything is
/// made.
enum SeriesCost {
    /// The default model's rate (Kling 2.5 Turbo), in rate-card dollars a second.
    static let usdPerSecond = 0.07
    /// A clip is at most about ten seconds however long the series says (the
    /// models stop at 8 to 15), so the estimate stops there too.
    static let typicalCeiling = 10

    static func perVideoUSD(seconds: Int?) -> Double {
        usdPerSecond * Double(min(max(1, seconds ?? 5), typicalCeiling))
    }
}

extension AppSession {
    /// Reads this month's usage. Keeps what it had on failure: a screen that
    /// cannot read the number should not flip somebody to zero.
    func refreshCredits() async {
        do {
            let response = try await client.rpc("credits_standing").execute()
            credits = try JSONDecoder().decode(CreditsStanding.self, from: response.data)
        } catch {
            // Left as it was.
        }
    }

    /// The three paid tiers as the server defines them. Fetched once.
    func loadPlanTiers() async {
        guard planTiers.isEmpty else { return }
        do {
            let rows: [PlanTierInfo] = try await client.rpc("plan_tiers").execute().value
            planTiers = rows.sorted { $0.tier < $1.tier }
        } catch {
            // The paywall falls back to `Tier.fallbackUsage` and friends.
        }
    }

    /// The plan this person is on: 0 free, 1 Pro, 2 Max, 3 Ultra.
    var planRank: Int {
        if let credits { return credits.tier }
        if let tier = subscription?.tier { return tier }
        return subscription?.isPro == true ? 1 : 0
    }

    /// The month a price is measured against: this person's own, or -- for
    /// somebody on Free, whose month makes nothing -- Pro's, which is what they
    /// would buy to make it.
    var usageBudgetUSD: Double {
        if let budget = credits?.budgetUSD, budget > 0, (credits?.tier ?? 0) >= 1 { return budget }
        return planTiers.first { $0.tier == 1 }?.budgetUSD ?? Tier.pro.fallbackBudgetUSD
    }

    /// How much of the month something priced in rate-card dollars takes, 0
    /// to 100. Nil while nothing has priced it.
    func usageShare(usd: Double?) -> Double? {
        guard let usd, usd >= 0, usageBudgetUSD > 0 else { return nil }
        return 100 * usd / usageBudgetUSD
    }

    /// The same, for a price as the server hands it over.
    func usageShare(of cost: ModelCost?) -> Double? {
        guard let cost, cost.unit == "usd" else { return nil }
        return usageShare(usd: cost.amount)
    }
}
