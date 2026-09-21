import Foundation
import StoreKit
import Supabase

/// Autocast Pro from the app's side.
///
/// The phone never decides who is Pro. It hands Apple's signed transactions to
/// `verify-purchase`, which checks Apple's signature and writes the row, and
/// then reads the answer back through `my_plan()`. Every purchase carries the
/// user's id as its appAccountToken, so a receipt only ever counts for the
/// account that bought it.
extension AppSession {
    static let proProductIDs = ["autocast.pro.yearly", "autocast.pro.monthly"]

    func refreshSubscription() async {
        do {
            let response = try await client.rpc("my_plan").execute()
            subscription = try JSONDecoder().decode(MyPlan.self, from: response.data)
        } catch {
            // Keep what we had: a failed read must not flip someone to free.
        }
    }

    /// Sends whatever StoreKit currently entitles this Apple ID to.
    func syncPurchases() async {
        var signed: [String] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               Self.proProductIDs.contains(transaction.productID) {
                signed.append(result.jwsRepresentation)
            }
        }
        guard !signed.isEmpty else { return }
        // Silent: this runs at every launch, and a receipt the server will not
        // take (bought by another account, or a sandbox one that has lapsed)
        // must not greet somebody with an error they cannot act on.
        await send(signed, announce: false)
    }

    /// Straight after a purchase in the paywall.
    func completePurchase(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            lastError = "Apple couldn’t confirm that purchase."
            return
        }
        // They just tapped Subscribe: a failure here is worth saying.
        await send([result.jwsRepresentation], announce: true)
        await transaction.finish()
    }

    /// Renewals, refunds and purchases from elsewhere while the app is open.
    func listenForTransactions() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await send([result.jwsRepresentation], announce: false)
                await transaction.finish()
            }
        }
    }

    private func send(_ signed: [String], announce: Bool) async {
        do {
            try await client.functions.invoke(
                "verify-purchase",
                options: FunctionInvokeOptions(body: ["transactions": signed])
            )
        } catch {
            let message = readableMessage(error)
            if announce { lastError = message } else { print("purchase sync: \(message)") }
        }
        await refreshSubscription()
    }
}

/// From `my_plan()`.
struct MyPlan: Decodable, Sendable, Equatable {
    struct Limits: Decodable, Sendable, Equatable {
        let aiWrites: Int
        let chat: Int
        let planDays: Int
        let accounts: Int

        enum CodingKeys: String, CodingKey {
            case chat, accounts
            case aiWrites = "ai_writes"
            case planDays = "plan_days"
        }
    }

    struct Used: Decodable, Sendable, Equatable {
        let aiWrites: Int
        let chat: Int

        enum CodingKeys: String, CodingKey {
            case chat
            case aiWrites = "ai_writes"
        }
    }

    let plan: String
    let isPro: Bool
    let isTrial: Bool
    let productId: String?
    let expiresAt: String?
    let autoRenew: Bool?
    let limits: Limits
    let used: Used

    enum CodingKeys: String, CodingKey {
        case plan, limits, used
        case isPro = "is_pro"
        case isTrial = "is_trial"
        case productId = "product_id"
        case expiresAt = "expires_at"
        case autoRenew = "auto_renew"
    }

    var expires: Date? { expiresAt.flatMap(PostgresTimestamp.parse) }

    /// "Pro", "Pro · Trial", "Free".
    var title: String {
        if isTrial { return "Pro trial" }
        return isPro ? "Pro" : "Free"
    }
}
