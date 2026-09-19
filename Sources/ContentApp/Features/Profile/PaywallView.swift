import SwiftUI
import StoreKit

/// Autocast Pro.
///
/// Our own layout (Abel, 19 Sep 2026, on StoreKit's stock view: "very ugly"),
/// built on StoreKit's products so every price, trial and renewal term shown
/// is the one Apple will actually charge in this person's country. Apple's
/// rules for the screen are all here: the price and period on each plan, what
/// happens after a trial, auto-renewal stated next to the button, Restore,
/// and the terms and privacy links.
///
/// Every benefit listed is a real, enforced difference (plans_catalog,
/// migration 0051) -- nothing promises results.
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

    private var yearly: Product? { products.first { $0.id == "autocast.pro.yearly" } }
    private var monthly: Product? { products.first { $0.id == "autocast.pro.monthly" } }
    private var choice: Product? { products.first { $0.id == selected } }

    /// "Save 44%": the yearly price against twelve months, from real prices.
    private var saving: Int? {
        guard let yearly, let monthly, monthly.price > 0 else { return nil }
        let twelve = monthly.price * 12
        let fraction = (twelve - yearly.price) / twelve
        let percent = Int((NSDecimalNumber(decimal: fraction).doubleValue * 100).rounded(.down))
        return percent >= 5 ? percent : nil
    }

    private func hasTrial(_ product: Product) -> Bool {
        trialEligible && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero

                VStack(spacing: 6) {
                    Text("Autocast Pro")
                        .font(.largeTitle.weight(.bold))
                    Text("Your whole month of content, planned and posted.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)
                .padding(.horizontal, 24)

                benefits
                    .padding(.top, 24)

                plans
                    .padding(.top, 24)
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { footer }
        .overlay(alignment: .topTrailing) { closeButton }
        .task { await load() }
    }

    // MARK: - Parts

    private var hero: some View {
        Image("pro-hero")
            .resizable()
            .scaledToFill()
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .accessibilityHidden(true)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 16) {
            Benefit(symbol: "calendar", title: "Plan the whole month", detail: "30-day plans instead of a week at a time")
            Benefit(symbol: "sparkles", title: "500 AI caption writes", detail: "Every month, instead of 5")
            Benefit(symbol: "bubble.left.and.text.bubble.right", title: "1,000 chat messages", detail: "Every month, instead of 20")
            Benefit(symbol: "person.2", title: "Up to 5 accounts", detail: "Instead of 1")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var plans: some View {
        if loading {
            ProgressView().frame(height: 150)
        } else if products.isEmpty {
            Text("Plans couldn’t load. Check your connection and try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .frame(height: 150)
        } else {
            VStack(spacing: 12) {
                if let yearly {
                    PlanCard(
                        title: "Yearly",
                        price: "\(yearly.displayPrice) / year",
                        detail: perMonth(yearly),
                        badge: hasTrial(yearly) ? trialText(yearly) : saving.map { "Save \($0)%" },
                        chosen: selected == yearly.id
                    ) { selected = yearly.id }
                }
                if let monthly {
                    PlanCard(
                        title: "Monthly",
                        price: "\(monthly.displayPrice) / month",
                        detail: "Cancel anytime",
                        badge: nil,
                        chosen: selected == monthly.id
                    ) { selected = monthly.id }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                Task { await buy() }
            } label: {
                Group {
                    if buying {
                        ProgressView()
                    } else if let choice, hasTrial(choice) {
                        Text("Start \(trialText(choice).lowercased())")
                    } else {
                        Text("Subscribe")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .controlSize(.large)
            .disabled(choice == nil || buying)

            Text(renewalTerms)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                Button(restoring ? "Restoring…" : "Restore") { Task { await restore() } }
                    .disabled(restoring)
                Button("Terms") { openURL(AutocastLinks.terms) }
                Button("Privacy") { openURL(AutocastLinks.privacy) }
            }
            .font(.footnote.weight(.medium))
            .tint(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 22)
        .padding(.trailing, 28)
        .accessibilityLabel("Close")
    }

    // MARK: - Words

    private func perMonth(_ yearly: Product) -> String {
        let monthlyEquivalent = yearly.price / 12
        let formatted = monthlyEquivalent.formatted(yearly.priceFormatStyle)
        return "\(formatted) a month, billed yearly"
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

    /// Apple requires the renewal terms beside the button.
    private var renewalTerms: String {
        guard let choice else { return "" }
        let period = choice.id == "autocast.pro.yearly" ? "year" : "month"
        if hasTrial(choice) {
            return "\(trialText(choice)), then \(choice.displayPrice) a \(period). Renews automatically until canceled. Cancel anytime in Settings."
        }
        return "\(choice.displayPrice) a \(period). Renews automatically until canceled. Cancel anytime in Settings."
    }

    // MARK: - StoreKit

    private func load() async {
        defer { loading = false }
        do {
            let loaded = try await Product.products(for: AppSession.proProductIDs)
            products = loaded.sorted { $0.price > $1.price }
            selected = (yearly ?? monthly)?.id
            if let group = yearly?.subscription?.subscriptionGroupID ?? monthly?.subscription?.subscriptionGroupID {
                trialEligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: group)
            }
        } catch {
            products = []
        }
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
                if session.subscription?.isPro == true { dismiss() }
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
            dismiss()
        } else {
            session.lastError = "No Autocast Pro subscription was found for this Apple ID."
        }
    }
}

// MARK: - Pieces

private struct Benefit: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 36, height: 36)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PlanCard: View {
    let title: String
    let price: String
    let detail: String
    let badge: String?
    let chosen: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 14) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(chosen ? Theme.accent : Color(uiColor: .tertiaryLabel))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.accent, in: Capsule())
                        }
                    }
                    Text(price).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(chosen ? Theme.accent : Color.clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
