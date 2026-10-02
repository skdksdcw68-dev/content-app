import Foundation

/// The three plans people can buy, and how each maps to a product, a plan code
/// on the server and a place in the ranking.
///
/// Netro, 29 Sep 2026: "we do need to provide a pricing things as well, like we
/// can split it, pro, max and 1 more so they choose and subscribe."
///
/// What each tier GIVES lives on the server (`plans_catalog`, read through
/// `plan_tiers()`), never here: a number typed into this file and a number the
/// server enforces would drift the first time either changed. This only names
/// the tiers and knows their product ids.
enum Tier: String, CaseIterable, Identifiable, Sendable {
    case pro, max, ultra

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pro: return "Pro"
        case .max: return "Max"
        case .ultra: return "Ultra"
        }
    }

    /// Where it ranks, the same number as `plans_catalog.tier`: 1 Pro, 2 Max,
    /// 3 Ultra. Free is 0.
    var rank: Int {
        switch self {
        case .pro: return 1
        case .max: return 2
        case .ultra: return 3
        }
    }

    /// The plan code the server stores. Pro kept its original code.
    var planCode: String { self == .pro ? "creator" : rawValue }

    /// Whether this tier has a yearly product. Ultra does not: Apple's US price
    /// ladder stops near $1,000, and $999.99 a year for 7,000 credits a month
    /// earns about 1% at full use (Netro approved monthly-only, 2 Oct 2026). Only
    /// a fallback for before StoreKit has answered; once it has, the products
    /// themselves decide.
    var sellsYearly: Bool { self != .ultra }

    /// The App Store product for this tier and billing period.
    func productID(yearly: Bool) -> String {
        "autocast.\(rawValue).\(yearly ? "yearly" : "monthly")"
    }

    /// Every product Autocast sells, for asking StoreKit and for filtering
    /// entitlements.
    static var allProductIDs: [String] {
        allCases.flatMap { [$0.productID(yearly: true), $0.productID(yearly: false)] }
    }

    /// Which tier a product belongs to.
    static func of(productID: String) -> Tier? {
        allCases.first { productID.hasPrefix("autocast.\($0.rawValue).") }
    }

    /// The tier a server plan code stands for. Nil for free and the trial.
    static func of(planCode: String) -> Tier? {
        allCases.first { $0.planCode == planCode }
    }

    /// Used until the server's own numbers arrive, so the paywall is never
    /// blank. They are the numbers `plans_catalog` was seeded with (0077).
    var fallbackCredits: Int {
        switch self {
        case .pro: return 800
        case .max: return 2_600
        case .ultra: return 7_000
        }
    }

    var fallbackPlanDays: Int {
        switch self {
        case .pro: return 30
        case .max: return 60
        case .ultra: return 90
        }
    }

    var fallbackAccounts: Int {
        switch self {
        case .pro: return 5
        case .max: return 10
        case .ultra: return 20
        }
    }

    /// The one that is pre-selected: the middle of three is what most people
    /// take, and it is what the badge says.
    static let recommended: Tier = .max
}

/// "800", "2,600": a count of credits the way people read one.
enum CreditFormat {
    static func text(_ credits: Int) -> String {
        credits.formatted(.number.grouping(.automatic))
    }
}
