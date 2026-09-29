import Foundation
import Supabase

/// What this month's credits stand at, from `credits_standing()` (0077).
///
/// Generation is paid for in credits: one is a tenth of a cent of what the
/// provider charges. The number beside the send button is what one request
/// costs; this is how many are left. Read without spending anything.
struct CreditsStanding: Decodable, Equatable, Sendable {
    let plan: String
    let name: String?
    /// 0 free, 1 Pro, 2 Max, 3 Ultra.
    let tier: Int
    let allowance: Int
    let used: Int
    let left: Int
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case plan, name, tier, allowance, used, left
        case resetsAt = "resets_at"
    }

    var resets: Date? { resetsAt.flatMap(PostgresTimestamp.parse) }

    /// How much of the month's credits is still there, 0 to 1.
    var fractionLeft: Double {
        guard allowance > 0 else { return 0 }
        return min(1, max(0, Double(left) / Double(allowance)))
    }
}

/// One paid tier, from `plan_tiers()`: what it gives, as the server enforces it.
struct PlanTierInfo: Decodable, Equatable, Sendable, Identifiable {
    let code: String
    let name: String
    let tier: Int
    let credits: Int
    let chat: Int
    let planDays: Int
    let accounts: Int

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code, name, tier, credits, chat, accounts
        case planDays = "plan_days"
    }
}

/// What a video in a series is expected to cost, in credits, for the sentence
/// that says what a month of posts draws on. An estimate, said as one: the real
/// price is the model's, at the length asked, and is shown before anything is
/// made.
enum SeriesCost {
    /// About eight cents a second: the default model's rate at 768p.
    static let creditsPerSecond = 80
    /// A clip is at most about ten seconds however long the series says (the
    /// models stop at 8 to 15), so the estimate stops there too.
    static let typicalCeiling = 10

    static func perVideo(seconds: Int?) -> Int {
        creditsPerSecond * min(max(1, seconds ?? 5), typicalCeiling)
    }
}

extension AppSession {
    /// Reads this month's credits. Keeps what it had on failure: a screen that
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
            // The paywall falls back to `Tier.fallbackCredits` and friends.
        }
    }

    /// The plan this person is on: 0 free, 1 Pro, 2 Max, 3 Ultra.
    var planRank: Int {
        if let credits { return credits.tier }
        if let tier = subscription?.tier { return tier }
        return subscription?.isPro == true ? 1 : 0
    }
}
