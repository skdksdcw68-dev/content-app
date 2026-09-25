import SwiftUI
import StoreKit
import UIKit

/// Autocast Pro, in Drobe's shape.
///
/// Abel, 22 Sep 2026: "match it exactly with the Drobe pro sheet, same
/// behaviour and things." Drobe's `app/subscription.tsx`: a sheet with the
/// title in the bar and an X on the left; a centred headline and a sentence;
/// one card headed INCLUDED WITH PRO with green check marks; Monthly and
/// Annual side by side, the annual one wearing SAVE n%, the chosen one
/// outlined in green; Subscribe; the renewal line; Restore purchases; Terms
/// of Use · Privacy Policy. A subscriber gets a status sheet instead of a
/// pitch -- PRO ACTIVE, when it renews, their benefits, Manage subscription.
///
/// Only things Pro actually unlocks are listed. Every number is a limit the
/// server enforces (plans_catalog, migrations 0002 and 0051).
struct PaywallView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var products: [Product] = []
    @State private var selected: Product.ID?
    @State private var trialEligible = false
    @State private var loading = true
    @State private var buying = false
    @State private var restoring = false
    @State private var managing = false

    /// Set when shown as an onboarding step rather than a sheet.
    private let onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var yearly: Product? { products.first { $0.id == "autocast.pro.yearly" } }
    private var monthly: Product? { products.first { $0.id == "autocast.pro.monthly" } }
    private var choice: Product? { products.first { $0.id == selected } }
    private var isPro: Bool { session.subscription?.isPro == true }

    /// Drobe's list, translated: what Pro unlocks and nothing it does not.
    private static let features = [
        "Plan 30 days ahead instead of 7",
        "500 captions and posts written for you a month",
        "1,000 chat messages a month",
        "Post to 5 accounts",
        "New features as they land",
    ]

    /// "SAVE 44%": the yearly price against twelve months, from real prices.
    private var saving: Int? {
        guard let yearly, let monthly, monthly.price > 0 else { return nil }
        let twelve = monthly.price * 12
        let fraction = (twelve - yearly.price) / twelve
        let percent = Int((NSDecimalNumber(decimal: fraction).doubleValue * 100).rounded())
        return percent > 0 ? percent : nil
    }

    private func hasTrial(_ product: Product) -> Bool {
        trialEligible && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
    }

    /// The free trial when this person can have one, otherwise the saving.
    /// Works from the remembered saving too, so the badge is there on the
    /// first frame along with the price.
    private func yearlyBadge(saving: Int?) -> String? {
        if let yearly, hasTrial(yearly) { return trialText(yearly).uppercased() }
        return saving.map { "SAVE \($0)%" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if isPro {
                        active
                    } else {
                        pitch
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("Autocast Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A sheet closes with an X, not a back chevron.
                ToolbarItem(placement: .topBarLeading) {
                    Button { close() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .manageSubscriptionsSheet(isPresented: $managing)
        .task { await load() }
    }

    // MARK: - The pitch

    private var pitch: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Post every day, hands off")
                    .font(.system(size: 28, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A month planned at a time, every caption written for you, and posts to every account you run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 16)

            FeaturesCard(label: "INCLUDED WITH PRO", features: Self.features)
                .padding(.top, 20)

            pricing
                .padding(.top, 32)

            VStack(spacing: 12) {
                Button {
                    Task { await buy() }
                } label: {
                    Group {
                        if buying {
                            ProgressView().tint(Theme.onAccent)
                        } else if let choice, hasTrial(choice) {
                            Text("Start \(trialText(choice).lowercased())")
                        } else {
                            Text("Subscribe")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(RemiFilledButtonStyle())
                .controlSize(.large)
                .disabled(choice == nil || buying)

                Text(renewalTerms)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await restore() }
                } label: {
                    Text(restoring ? "Restoring…" : "Restore purchases")
                        .font(.footnote.weight(.semibold))
                        .underline()
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(restoring || buying)
                .padding(.top, 4)

                // Required, not decorative: a screen selling an auto-renewable
                // subscription must carry working links to both.
                HStack(spacing: 8) {
                    Button("Terms of Use") { openURL(AutocastLinks.terms) }
                    Text("·")
                    Button("Privacy Policy") { openURL(AutocastLinks.privacy) }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .tint(.secondary)
                .underline()
                .padding(.top, 2)
            }
            .padding(.top, 32)
        }
    }

    /// What to print on the two cards: the live prices when StoreKit has
    /// answered, otherwise the ones it gave last time on this phone.
    ///
    /// 🔴 There is no "loading" state left while anything is known. The words
    /// "Loading plans…" were shown on EVERY open, because the products lived in
    /// a `@State` that a re-presented sheet is born without (Abel, 25 Sep 2026:
    /// "it always says that it's loading the plans"). The products are held on
    /// the session now and fetched at launch, so the usual case is that they
    /// are simply there.
    private var shown: (monthly: String, yearly: String, saving: Int?)? {
        if let monthly, let yearly {
            return (monthly.displayPrice, yearly.displayPrice, saving)
        }
        // First run on a new phone, or StoreKit still answering.
        if let remembered = RememberedPricing.saved {
            return (remembered.monthly, remembered.yearly, remembered.saving)
        }
        return nil
    }

    /// Only a live `Product` can be bought, so the cards are tappable a moment
    /// after they are readable. Prices first, then the button: the opposite of
    /// making somebody wait for both.
    private var canChoose: Bool { !products.isEmpty }

    @ViewBuilder
    private var pricing: some View {
        if let shown {
            HStack(alignment: .top, spacing: 12) {
                PlanCard(
                    label: "Monthly",
                    labelIsGreen: false,
                    badge: nil,
                    price: shown.monthly,
                    period: "/mo",
                    footnote: "Perfect to test the waters",
                    footnoteStrong: false,
                    emphasised: false,
                    chosen: selected != nil && selected == monthly?.id
                ) { if let monthly { selected = monthly.id } }
                .disabled(!canChoose)

                PlanCard(
                    label: "Annual",
                    labelIsGreen: true,
                    badge: yearlyBadge(saving: shown.saving),
                    price: shown.yearly,
                    period: "/yr",
                    footnote: "Billed once a year",
                    footnoteStrong: true,
                    emphasised: true,
                    chosen: selected != nil && selected == yearly?.id
                ) { if let yearly { selected = yearly.id } }
                .disabled(!canChoose)
            }
            .animation(.snappy(duration: 0.2), value: canChoose)
        } else if loading {
            // Nothing known at all: first launch, offline, before any fetch.
            HStack(alignment: .top, spacing: 12) {
                SkeletonCard(height: 132)
                SkeletonCard(height: 132)
            }
        } else if products.isEmpty {
            Text("Plans aren’t available right now. Please check your connection and try again.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        }
    }

    // MARK: - Already Pro

    /// A status sheet, not a sales pitch.
    private var active: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.bold))
                    Text("PRO ACTIVE")
                        .font(.caption2.weight(.bold))
                        .kerning(1)
                }
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.accent, in: Capsule())

                Text("You’re on Autocast Pro")
                    .font(.system(size: 28, weight: .heavy))
                    .multilineTextAlignment(.center)

                if let plan = session.subscription, let date = plan.expires {
                    Text(renewalLine(plan, date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 16)

            FeaturesCard(label: "YOUR BENEFITS", features: Self.features)
                .padding(.top, 20)

            VStack(spacing: 12) {
                Button {
                    managing = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                        Text("Manage subscription")
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(RemiFilledButtonStyle())
                .controlSize(.large)
                .disabled(session.subscription?.productId == "owner")

                Text("Plan changes and cancellation happen in your Apple ID settings")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
        }
    }

    // MARK: - Words

    private func renewalLine(_ plan: MyPlan, _ date: Date) -> String {
        let when = date.formatted(date: .long, time: .omitted)
        if plan.isTrial { return "Trial ends \(when)" }
        return plan.autoRenew == false ? "Ends \(when)" : "Renews \(when)"
    }

    private func trialText(_ product: Product) -> String {
        guard let period = product.subscription?.introductoryOffer?.period else { return "Free trial" }
        let unit: String
        switch period.unit {
        case .day: unit = period.value == 1 ? "day" : "days"
        case .week: unit = period.value == 1 ? "week" : "weeks"
        case .month: unit = period.value == 1 ? "month" : "months"
        case .year: unit = period.value == 1 ? "year" : "years"
        @unknown default: unit = "days"
        }
        return "\(period.value) \(unit) free"
    }

    /// Apple requires the price and length beside the button.
    private var renewalTerms: String {
        guard let choice else {
            return "Renews automatically until cancelled. Cancel anytime in your Apple ID settings."
        }
        let period = choice.id == "autocast.pro.yearly" ? "year" : "month"
        if hasTrial(choice) {
            return "\(trialText(choice)), then \(choice.displayPrice) a \(period). Renews automatically until cancelled. Cancel anytime in your Apple ID settings."
        }
        return "\(choice.displayPrice) a \(period). Renews automatically until cancelled. Cancel anytime in your Apple ID settings."
    }

    // MARK: - StoreKit

    private func load() async {
        // Whatever the session already fetched at launch, which is the usual
        // case and costs nothing.
        if !session.storeProducts.isEmpty {
            products = session.storeProducts
            selected = (yearly ?? monthly)?.id
            loading = false
        }

        if products.isEmpty {
            await session.loadProducts()
            products = session.storeProducts
            selected = (yearly ?? monthly)?.id
            loading = false
        }

        // 🔴 Deliberately after `loading = false`. Trial eligibility is a
        // second round trip, and holding the prices behind it meant the sheet
        // said "Loading plans…" for both. The badge can arrive late; the price
        // cannot.
        guard let group = yearly?.subscription?.subscriptionGroupID
            ?? monthly?.subscription?.subscriptionGroupID else { return }
        trialEligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: group)
    }

    private func buy() async {
        guard let choice else { return }
        buying = true
        defer { buying = false }
        var options: Set<Product.PurchaseOption> = []
        // Bound to this Autocast user, so the server refuses anyone else's receipt.
        if let userID = session.userID { options.insert(.appAccountToken(userID)) }
        do {
            switch try await choice.purchase(options: options) {
            case .success(let verification):
                await session.completePurchase(verification)
                if session.subscription?.isPro == true { close() }
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            session.lastError = "The purchase didn’t go through. You weren’t charged."
        }
    }

    private func restore() async {
        restoring = true
        defer { restoring = false }
        try? await AppStore.sync()
        await session.syncPurchases()
        if session.subscription?.isPro == true {
            close()
        } else {
            session.lastError = "No Autocast Pro subscription was found for this Apple ID."
        }
    }
}

// MARK: - Pieces

/// Drobe's features card: a small green heading, then a check in a pale
/// green circle beside each line.
private struct FeaturesCard: View {
    let label: String
    let features: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.proGreen)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(features, id: \.self) { feature in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.proGreen)
                            .frame(width: 24, height: 24)
                            .background(Theme.proGreenSoft, in: Circle())
                        Text(feature)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// One plan, Drobe's card: the label, the price with its period, a footnote,
/// and a green outline when it is the chosen one.
private struct PlanCard: View {
    let label: String
    let labelIsGreen: Bool
    let badge: String?
    let price: String
    let period: String
    let footnote: String
    let footnoteStrong: Bool
    let emphasised: Bool
    let chosen: Bool
    let tap: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(label)
                        .font(.subheadline.weight(labelIsGreen ? .bold : .medium))
                        .foregroundStyle(labelIsGreen ? Theme.proGreen : Color.secondary)
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.proGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.proGreenSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(price)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(period)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(footnote)
                    .font(footnoteStrong ? .caption2.weight(.semibold) : .caption)
                    .foregroundStyle(footnoteStrong ? Color.secondary : Color(uiColor: .tertiaryLabel))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(uiColor: .secondarySystemBackground), in: shape)
            .overlay {
                shape.strokeBorder(
                    chosen ? Theme.proGreen : Color(uiColor: .separator),
                    lineWidth: emphasised || chosen ? 2 : 1
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
