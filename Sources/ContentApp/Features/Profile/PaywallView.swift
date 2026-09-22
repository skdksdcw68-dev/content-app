import SwiftUI
import StoreKit
import UIKit

/// Autocast Pro.
///
/// Rebuilt from nothing on 22 Sep 2026 (Abel: "the pro sheet, change it
/// completely no mercy"). The old one was a picture in a rounded box, a list of
/// four good things, and two stacked rows of prices -- the layout every app
/// ships, which is why it persuaded nobody.
///
/// This one argues instead of announcing. The picture runs to the edges and
/// under the status bar; the middle is a Free-against-Pro table, because the
/// difference is the only thing worth showing and a list of benefits hides it;
/// the two prices sit side by side where they can be compared at a glance; and
/// the button never leaves the bottom of the screen.
///
/// Every number in the table is a limit the server enforces (plans_catalog,
/// migrations 0002 and 0051). Nothing here promises a result.
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

                comparison
                    .padding(.horizontal, 16)
                    .padding(.top, 24)

                plans
                    .padding(.horizontal, 16)
                    .padding(.top, 18)

                Text("AI video generation stays bring-your-own: connect your own generator and Autocast never bills you for frames.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)
                    .padding(.top, 18)
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { footer }
        .overlay(alignment: .topTrailing) { closeButton }
        .task { await load() }
    }

    // MARK: - The picture

    /// Edge to edge and under the clock, fading into the page. A picture inside
    /// a rounded box reads as an illustration; a picture the screen starts with
    /// reads as the product.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let art = UIImage(named: "pro-hero") {
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.11, green: 0.11, blue: 0.13), Color.black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .frame(height: 360)
            .frame(maxWidth: .infinity)
            .clipped()

            // Dark at the bottom so the words hold on any picture, and fading
            // into the page colour so the photo has no edge.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.75), location: 0.55),
                    .init(color: .black.opacity(0.92), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 360)

            VStack(alignment: .leading, spacing: 8) {
                Text("AUTOCAST PRO")
                    .font(.caption.weight(.heavy))
                    .kerning(1.6)
                    .foregroundStyle(.white.opacity(0.7))

                Text("A month of posts,\nwritten and posted for you")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .frame(height: 360)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Free against Pro

    private var comparison: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Free")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 62)
                Text("Pro")
                    .font(.footnote.weight(.heavy))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 62)
                    .padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ForEach(Array(Self.rows.enumerated()), id: \.element.title) { index, row in
                if index > 0 { Divider().padding(.leading, 18) }
                ComparisonRow(row: row)
            }
        }
        .padding(.bottom, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The four enforced differences, in the order they are felt.
    private static let rows: [ComparisonRow.Row] = [
        .init(title: "How far ahead you can plan", free: "7 days", pro: "30 days"),
        .init(title: "Captions and posts written for you", free: "5 / mo", pro: "500 / mo"),
        .init(title: "Chat messages", free: "20 / mo", pro: "1,000 / mo"),
        .init(title: "Accounts it posts to", free: "1", pro: "5"),
    ]

    // MARK: - The two prices

    @ViewBuilder
    private var plans: some View {
        if loading {
            ProgressView().frame(height: 150).frame(maxWidth: .infinity)
        } else if products.isEmpty {
            Text("Plans couldn’t load. Check your connection and try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(height: 150)
        } else {
            // Side by side: a year and a month are a comparison, and stacking
            // them turns the comparison into scrolling.
            HStack(alignment: .top, spacing: 12) {
                if let yearly {
                    PriceCard(
                        title: "Yearly",
                        price: yearly.displayPrice,
                        period: "a year",
                        detail: perMonth(yearly),
                        ribbon: hasTrial(yearly) ? trialText(yearly) : saving.map { "SAVE \($0)%" },
                        chosen: selected == yearly.id
                    ) { selected = yearly.id }
                }
                if let monthly {
                    PriceCard(
                        title: "Monthly",
                        price: monthly.displayPrice,
                        period: "a month",
                        detail: "Cancel anytime",
                        ribbon: nil,
                        chosen: selected == monthly.id
                    ) { selected = monthly.id }
                }
            }
        }
    }

    // MARK: - The bar that never leaves

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                Task { await buy() }
            } label: {
                Group {
                    if buying {
                        ProgressView().tint(Theme.onAccent)
                    } else if let choice, hasTrial(choice) {
                        Text("Start \(trialText(choice).lowercased())")
                    } else {
                        Text("Get Autocast Pro")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .controlSize(.large)
            .disabled(choice == nil || buying)

            Text(renewalTerms)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                Button(restoring ? "Restoring…" : "Restore") { Task { await restore() } }
                    .disabled(restoring)
                Button("Terms") { openURL(AutocastLinks.terms) }
                Button("Privacy") { openURL(AutocastLinks.privacy) }
            }
            .font(.caption.weight(.medium))
            .tint(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var closeButton: some View {
        Button {
            close()
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.35), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 14)
        .padding(.trailing, 18)
        .accessibilityLabel("Close")
    }

    // MARK: - Words

    private func perMonth(_ yearly: Product) -> String {
        let monthlyEquivalent = yearly.price / 12
        let formatted = monthlyEquivalent.formatted(yearly.priceFormatStyle)
        return "\(formatted) a month"
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

/// One line of the table: what it is, what Free gets, what Pro gets.
private struct ComparisonRow: View {
    struct Row {
        let title: String
        let free: String
        let pro: String
    }

    let row: Row

    var body: some View {
        HStack(spacing: 0) {
            Text(row.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.free)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 62)

            Text(row.pro)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 62)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title). Free: \(row.free). Pro: \(row.pro).")
    }
}

/// One price, as a card tall enough to read from across the room.
private struct PriceCard: View {
    let title: String
    let price: String
    let period: String
    let detail: String
    let ribbon: String?
    let chosen: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(price)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(period)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .padding(16)
            .padding(.top, ribbon == nil ? 0 : 8)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(chosen ? Theme.accent : Color.clear, lineWidth: 2)
            )
            .overlay(alignment: .top) {
                if let ribbon {
                    Text(ribbon.uppercased())
                        .font(.caption2.weight(.heavy))
                        .kerning(0.5)
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.accent, in: Capsule())
                        .offset(y: -9)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
