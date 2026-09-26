import Foundation
import Supabase

/// How far this account can go this month, read without spending anything.
///
/// Abel, 26 Sep 2026: "why does the user is not allowed to see the costs and
/// the credits how far they can go?? plans also cost credits btw."
///
/// The server has always known -- `consume_quota` is the thing that refuses --
/// but the only way to hear from it was to try to spend. `quota_standing`
/// reads the same counters and the same plan and changes nothing, so the plan
/// flow and the generator can say what a decision costs BEFORE it is made.
struct QuotaStanding: Decodable, Equatable, Sendable {
    let kind: String
    let used: Int
    let limitValue: Int

    var left: Int { max(0, limitValue - used) }

    enum CodingKeys: String, CodingKey {
        case kind, used
        case limitValue = "limit_value"
    }
}

extension AppSession {
    /// This month's allowances: how many videos and images are left. Empty on
    /// failure -- a screen that cannot read the number says nothing rather
    /// than inventing one.
    func quotaStanding() async -> [QuotaStanding] {
        do {
            return try await client.rpc("quota_standing").execute().value
        } catch {
            return []
        }
    }
}
