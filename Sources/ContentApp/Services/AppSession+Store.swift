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
/// The last prices StoreKit gave us, kept so the paywall opens on numbers.
///
/// Abel, 25 Sep 2026: "when you go to the upgrade place it always says it's
/// loading the plans -- instead we need it hardcoded already, so it doesn't
/// require any time for the users."
///
/// Not hardcoded, though: a hardcoded "$29.99" is a lie in every storefront
/// that is not the US, and it would go stale the day a price changes. What is
/// remembered is what Apple last said **on this phone, in this storefront**,
/// which is right the first time and right after that. The live fetch still
/// runs and still wins; this only decides what is on screen for the second it
/// takes. The currency code is stored with it, so a person who travels does
/// not see yesterday's currency against today's.
struct RememberedPricing: Codable, Equatable {
    var monthly: String
    var yearly: String
    var saving: Int?
    var currency: String

    private static let key = "store.pricing"

    static var saved: RememberedPricing? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RememberedPricing.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

extension AppSession {
    static let proProductIDs = ["autocast.pro.yearly", "autocast.pro.monthly"]

    /// Fetched once at launch so the paywall never has to wait for StoreKit.
    ///
    /// Held here rather than on the view because a `@State` in a sheet is born
    /// empty every time the sheet is presented -- which is exactly why the
    /// words "Loading plans…" appeared on every single open, even the tenth.
    func loadProducts() async {
        guard storeProducts.isEmpty else { return }
        guard let loaded = try? await Product.products(for: Self.proProductIDs) else { return }
        storeProducts = loaded.sorted { $0.price > $1.price }
        rememberPricing()
    }

    /// Writes down what was just fetched, for the next cold start.
    private func rememberPricing() {
        guard
            let yearly = storeProducts.first(where: { $0.id == "autocast.pro.yearly" }),
            let monthly = storeProducts.first(where: { $0.id == "autocast.pro.monthly" }),
            monthly.price > 0
        else { return }

        let twelve = monthly.price * 12
        let fraction = (twelve - yearly.price) / twelve
        let percent = Int((NSDecimalNumber(decimal: fraction).doubleValue * 100).rounded())

        RememberedPricing(
            monthly: monthly.displayPrice,
            yearly: yearly.displayPrice,
            saving: percent > 0 ? percent : nil,
            currency: monthly.priceFormatStyle.currencyCode
        ).save()
    }

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
        // 🔴 Refresh even with nothing to send. This used to return here,
        // so Restore -- whose only path is this function -- made ZERO server
        // calls on a phone StoreKit reported no entitlements for, and then
        // told the person no subscription was found. Somebody entitled through
        // an Apple server notification could never get it back that way.
        guard !signed.isEmpty else {
            await refreshSubscription()
            return
        }
        // Silent: this runs at every launch, and a receipt the server will not
        // take (bought by another account, or a sandbox one that has lapsed)
        // must not greet somebody with an error they cannot act on.
        await send(signed, announce: false)
    }

    /// Sent again once the account is no longer the anonymous one it started
    /// as, so a purchase made before signing in follows the person.
    ///
    /// Without this the receipt keeps the old anonymous id and the server has
    /// to decide on its own whether to honour it; with it, the claim is made
    /// while the person is present and can be told if it fails.
    func claimPurchasesAfterSignIn() async {
        var signed: [String] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               Self.proProductIDs.contains(transaction.productID) {
                signed.append(result.jwsRepresentation)
            }
        }
        guard !signed.isEmpty else { return }
        await send(signed, announce: true)
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
