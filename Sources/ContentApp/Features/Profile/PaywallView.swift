import SwiftUI
import StoreKit
import UIKit

/// Autocast's plans: Pro, Max and Ultra, each monthly or yearly.
///
/// Netro, 29 Sep 2026: "we do need to provide a pricing things as well, like we
/// can split it, pro, max and 1 more so they choose and subscribe."
///
/// The shape is still Drobe's (Abel, 22 Sep 2026: "match it exactly with the
/// Drobe pro sheet"): a centred headline, a card of what is included with green
/// check marks, the plans as cards with the chosen one outlined in green,
/// Subscribe, the renewal line, Restore purchases, Terms of Use · Privacy
/// Policy. What changed is that there are three plans instead of one, so the
/// choice is now two questions -- how long, and how much -- and the second one
/// is the interesting one, because Pro, Max and Ultra differ in one thing that
/// matters to a person: how much they can make each month. That is credits.
///
/// Every number about what a plan GIVES is read from the server
/// (`plan_tiers()`), never typed here: a figure on this screen that the server
/// does not enforce is the kind of lie that ends in a refund request. Every
/// number about what it COSTS is StoreKit's, in the person's own currency.
///
/// A subscriber gets the same screen with a status header instead of the pitch,
/// and the button changes their plan. Apple does the rest: an upgrade is
/// immediate and prorated, a downgrade waits for the renewal.
struct PaywallView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var products: [Product] = []
    @State private var tier: Tier = Tier.recommended
    @State private var yearly = true
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

    // MARK: - What is chosen

    private var isSubscriber: Bool { session.subscription?.isPro == true }

    /// The tier they are on now, when they are on one. A trial is Pro.
    private var currentTier: Tier? {
        guard isSubscriber else { return nil }
        let rank = session.planRank
        return Tier.allCases.first { $0.rank == rank }
    }

    private func product(_ tier: Tier, yearly: Bool) -> Product? {
        let id = tier.productID(yearly: yearly)
        return products.first { $0.id == id }
    }

    private var choice: Product? { product(tier, yearly: yearly) }

    /// The tiers to show: all three until StoreKit has answered, then only the
    /// ones App Store Connect actually sells. A tier with no product is a row
    /// that cannot be bought, and the paywall lights it up by itself the day
    /// the product exists.
    private var offered: [Tier] {
        guard !products.isEmpty else { return Tier.allCases }
        let sold = Tier.allCases.filter {
            product($0, yearly: true) != nil || product($0, yearly: false) != nil
        }
        return sold.isEmpty ? Tier.allCases : sold
    }

    /// The product they already have, so the button can say so.
    private var isCurrentChoice: Bool {
        guard let choice else { return false }
        return session.subscription?.productId == choice.id
    }

    // MARK: - What a tier gives, from the server

    private struct Facts {
        let credits: Int
        let planDays: Int
        let accounts: Int
    }

    private func facts(_ tier: Tier) -> Facts {
        if let row = session.planTiers.first(where: { $0.code == tier.planCode }) {
            return Facts(credits: row.credits, planDays: row.planDays, accounts: row.accounts)
        }
        return Facts(credits: tier.fallbackCredits, planDays: tier.fallbackPlanDays, accounts: tier.fallbackAccounts)
    }

    /// What is included, as short lines. Only things the tier really has.
    private func bullets(_ tier: Tier) -> [String] {
        let facts = facts(tier)
        var lines: [String] = ["\(CreditFormat.text(facts.credits)) credits every month"]
        switch tier {
        case .pro:
            lines.append("Video and picture models, including Kling 3 and Veo 3.1 Fast")
        case .max:
            lines.append("Everything in Pro")
            lines.append("Veo 3.1 with sound and Seedance 2.5, up to 30 seconds")
        case .ultra:
            lines.append("Everything in Max")
            lines.append("The most credits, for a series every day")
        }
        lines.append("Plan \(facts.planDays) days ahead")
        lines.append("Post to \(facts.accounts) accounts")
        return lines
    }

    // MARK: - What it costs, from StoreKit

    /// The price to print: live when StoreKit has answered, otherwise what it
    /// said last time on this phone -- so the cards are never blank while
    /// anything is known.
    ///
    /// 🔴 There is no "loading" state left while anything is known. The words
    /// "Loading plans…" were shown on EVERY open once, because the products
    /// lived in a `@State` that a re-presented sheet is born without (Abel,
    /// 25 Sep 2026). They are held on the session now and fetched at launch.
    private func priceText(_ tier: Tier, yearly: Bool) -> String? {
        if let live = product(tier, yearly: yearly) { return live.displayPrice }
        return RememberedPricing.saved?.prices[tier.productID(yearly: yearly)]
    }

    /// "$20.83/mo" for a yearly plan, from the real price.
    private func perMonthText(_ tier: Tier) -> String? {
        guard let live = product(tier, yearly: true) else { return nil }
        let monthly: Decimal = live.price / 12
        return monthly.formatted(live.priceFormatStyle)
    }

    /// "SAVE 31%": the yearly price against twelve months of the monthly one.
    private func saving(_ tier: Tier) -> Int? {
        guard let year = product(tier, yearly: true),
              let month = product(tier, yearly: false),
              month.price > 0 else { return nil }
        let twelve: Decimal = month.price * 12
        let fraction: Decimal = (twelve - year.price) / twelve
        let percent = Int((NSDecimalNumber(decimal: fraction).doubleValue * 100).rounded())
        return percent > 0 ? percent : nil
    }

    private func hasTrial(_ product: Product) -> Bool {
        trialEligible && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
    }

    private var canChoose: Bool { !products.isEmpty }

    // MARK: - The screen

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    billingPicker
                        .padding(.top, 20)
                    plans
                        .padding(.top, 16)
                    FeaturesCard(label: "INCLUDED WITH \(tier.name.uppercased())", features: bullets(tier))
                        .padding(.top, 20)
                    creditsNote
                        .padding(.top, 16)
                    footer
                        .padding(.top, 24)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("Autocast")
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

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if isSubscriber {
            status
        } else {
            pitch
        }
    }

    private var pitch: some View {
        VStack(spacing: 8) {
            Text("Make more. Post every day.")
                .font(.system(size: 28, weight: .heavy))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick how much you want to make each month. Every plan plans your posts, writes the captions and posts for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
    }

    /// A status header, not a sales pitch: which plan, when it renews, and how
    /// much of this month's credits is left.
    private var status: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                Text("\((session.subscription?.title ?? "PRO").uppercased()) ACTIVE")
                    .font(.caption2.weight(.bold))
                    .kerning(1)
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.accent, in: Capsule())

            Text("You’re on Autocast \(session.subscription?.title ?? "Pro")")
                .font(.system(size: 28, weight: .heavy))
                .multilineTextAlignment(.center)

            if let plan = session.subscription, let date = plan.expires {
                Text(renewalLine(plan, date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let credits = session.credits, credits.allowance > 0 {
                CreditsMeter(credits: credits)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 16)
    }

    // MARK: - Choosing

    private var billingPicker: some View {
        Picker("Billing", selection: $yearly) {
            Text("Monthly").tag(false)
            Text(yearlyLabel).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// "Annual · save 31%", from the real prices, once they are known.
    private var yearlyLabel: String {
        if let percent = saving(tier) { return "Annual · save \(percent)%" }
        return "Annual"
    }

    @ViewBuilder
    private var plans: some View {
        if priceText(.pro, yearly: yearly) == nil && loading {
            VStack(spacing: 10) {
                SkeletonCard(height: 76)
                SkeletonCard(height: 76)
                SkeletonCard(height: 76)
            }
        } else if priceText(.pro, yearly: yearly) == nil && products.isEmpty {
            Text("Plans aren’t available right now. Please check your connection and try again.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else {
            VStack(spacing: 10) {
                ForEach(offered) { option in
                    row(option)
                }
            }
            .animation(.snappy(duration: 0.2), value: yearly)
        }
    }

    private func row(_ option: Tier) -> some View {
        let price: String = priceText(option, yearly: yearly) ?? "—"
        let footnote: String? = yearly ? perMonthText(option).map { "\($0)/mo, billed yearly" } : nil
        return TierRow(
            name: option.name,
            badge: option == Tier.recommended ? "MOST POPULAR" : nil,
            credits: "\(CreditFormat.text(facts(option).credits)) credits a month",
            price: price,
            period: yearly ? "/yr" : "/mo",
            footnote: footnote,
            chosen: option == tier,
            isCurrent: option == currentTier
        ) {
            tier = option
        }
        .disabled(!canChoose && priceText(option, yearly: yearly) == nil)
    }

    private var creditsNote: some View {
        Text("Credits pay for what you make. A picture is 3 to 150 credits and a five-second video 60 to 800, and the number is shown before you make anything. They start again each month.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Buying

    private var footer: some View {
        VStack(spacing: 12) {
            Button {
                Task { await buy() }
            } label: {
                Group {
                    if buying {
                        ProgressView().tint(Theme.onAccent)
                    } else {
                        Text(buttonTitle)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .controlSize(.large)
            .disabled(choice == nil || buying || isCurrentChoice)

            Text(renewalTerms)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if isSubscriber {
                Button {
                    managing = true
                } label: {
                    Text("Manage subscription")
                        .font(.footnote.weight(.semibold))
                        .underline()
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(session.subscription?.productId == "owner")
                .padding(.top, 4)
            }

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
    }

    private var buttonTitle: String {
        guard let choice else { return "Subscribe to \(tier.name)" }
        if isSubscriber {
            return isCurrentChoice ? "Your current plan" : "Switch to \(tier.name)"
        }
        if hasTrial(choice) { return "Start \(trialText(choice).lowercased())" }
        return "Subscribe to \(tier.name)"
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
        let period = yearly ? "year" : "month"
        if hasTrial(choice) && !isSubscriber {
            return "\(trialText(choice)), then \(choice.displayPrice) a \(period). Renews automatically until cancelled. Cancel anytime in your Apple ID settings."
        }
        if isSubscriber && !isCurrentChoice {
            return "\(choice.displayPrice) a \(period). Moving up starts now and is prorated; moving down starts at your next renewal."
        }
        return "\(choice.displayPrice) a \(period). Renews automatically until cancelled. Cancel anytime in your Apple ID settings."
    }

    // MARK: - StoreKit

    private func load() async {
        // Whatever the session already fetched at launch, which is the usual
        // case and costs nothing.
        if !session.storeProducts.isEmpty {
            products = session.storeProducts
            loading = false
        }
        if products.isEmpty {
            await session.loadProducts()
            products = session.storeProducts
            loading = false
        }

        // Start on the tier they are on, or the recommended one -- as long as
        // it is one that is sold.
        if let currentTier { tier = currentTier }
        if !offered.contains(tier) { tier = offered.first ?? .pro }

        await session.loadPlanTiers()
        await session.refreshCredits()

        // 🔴 Deliberately after `loading = false`. Trial eligibility is a
        // second round trip, and holding the prices behind it meant the sheet
        // said "Loading plans…" for both. The badge can arrive late; the price
        // cannot.
        guard let group = products.first?.subscription?.subscriptionGroupID else { return }
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
                await session.refreshCredits()
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
        // Announced, not silent. Restore is a button somebody pressed on
        // purpose, so a server that refuses the receipt -- because it belongs
        // to another Autocast account -- has to say so. It used to swallow
        // that and show "none found", which is a different thing entirely and
        // sent people looking in the wrong place.
        await session.claimPurchasesAfterSignIn()
        await session.syncPurchases()
        await session.refreshCredits()
        if session.subscription?.isPro == true {
            close()
        } else if (session.lastError ?? "").isEmpty {
            session.lastError = "No Autocast subscription was found for this Apple ID."
        }
    }
}

// MARK: - Pieces

/// This month's credits as a bar and a sentence: how many are left, and when
/// they start again.
struct CreditsMeter: View {
    let credits: CreditsStanding

    private var resets: String {
        guard let date = credits.resets else { return "" }
        return " · back on \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: credits.fractionLeft)
                .tint(Theme.proGreen)
            Text("\(CreditFormat.text(credits.left)) of \(CreditFormat.text(credits.allowance)) credits left\(resets)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

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

/// One plan as a row: a radio mark, its name and what it gives, and its price.
/// The chosen one is outlined in green, as Drobe's cards are.
private struct TierRow: View {
    let name: String
    let badge: String?
    let credits: String
    let price: String
    let period: String
    let footnote: String?
    let chosen: Bool
    let isCurrent: Bool
    let tap: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 14) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(chosen ? Theme.proGreen : Color.secondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.primary)
                        if let badge {
                            PlanTag(text: badge)
                        }
                        if isCurrent {
                            PlanTag(text: "CURRENT")
                        }
                    }
                    Text(credits)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(price)
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(period)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let footnote {
                        Text(footnote)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: shape)
            .overlay {
                shape.strokeBorder(
                    chosen ? Theme.proGreen : Color(uiColor: .separator),
                    lineWidth: chosen ? 2 : 1
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A small pill: "MOST POPULAR", "CURRENT".
private struct PlanTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.proGreen)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.proGreenSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
