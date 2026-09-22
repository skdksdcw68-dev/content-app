import SwiftUI
import StoreKit
import UIKit

/// Autocast Pro.
///
/// Rebuilt again on 22 Sep 2026, this time to a reference Abel sent (a
/// wardrobe app's paywall): a title, a lineup picture, two small cards that
/// each say one thing and offer "Compare", a yearly plan wearing a MOST
/// POPULAR band, a monthly one under it, Continue, and the three links.
/// The comparison lives in its own sheet -- Free against Pro, ticks and
/// numbers -- so the paywall itself stays short enough to read whole.
///
/// Every number here is a limit the server enforces (plans_catalog,
/// migrations 0002 and 0051). Nothing promises a result.
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
    @State private var comparing = false

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

    private func hasTrial(_ product: Product) -> Bool {
        trialEligible && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Post every day")
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 60)

                lineup
                    .padding(.top, 18)

                HStack(spacing: 12) {
                    StatCard(top: .text("30"), label: "days planned ahead") { comparing = true }
                    StatCard(top: .symbol("lock.open"), label: "All features") { comparing = true }
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)

                plans
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { footer }
        .overlay(alignment: .topTrailing) { closeButton }
        .sheet(isPresented: $comparing) { CompareSheet() }
        .task { await load() }
    }

    // MARK: - The lineup

    /// A row of made videos, edge to edge, under the title. The picture is
    /// Abel's (asset `pro-lineup`); until it exists, six video-shaped tiles in
    /// six colours stand in, which is not a placeholder so much as the same
    /// idea drawn with shapes.
    @ViewBuilder
    private var lineup: some View {
        if let art = UIImage(named: "pro-lineup") {
            Image(uiImage: art)
                .resizable()
                .scaledToFill()
                .frame(height: 300)
                .frame(maxWidth: .infinity)
                .clipped()
                .accessibilityHidden(true)
        } else {
            LineupTiles()
                .frame(height: 230)
                .padding(.horizontal, 20)
                .accessibilityHidden(true)
        }
    }

    // MARK: - The two prices

    @ViewBuilder
    private var plans: some View {
        if loading {
            ProgressView().frame(height: 170).frame(maxWidth: .infinity)
        } else if products.isEmpty {
            Text("Plans couldn’t load. Check your connection and try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(height: 170)
        } else {
            VStack(spacing: 12) {
                if let yearly {
                    PlanCard(
                        band: hasTrial(yearly) ? trialText(yearly).uppercased() : "MOST POPULAR",
                        title: "Yearly plan",
                        subtitle: "\(yearly.displayPrice) billed annually",
                        trailing: "\(perMonth(yearly)) / mo",
                        chosen: selected == yearly.id
                    ) { selected = yearly.id }
                }
                if let monthly {
                    PlanCard(
                        band: nil,
                        title: "Monthly",
                        subtitle: nil,
                        trailing: "\(monthly.displayPrice) / mo",
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
                        Text("Continue")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .controlSize(.large)
            .disabled(choice == nil || buying)

            if !renewalTerms.isEmpty {
                Text(renewalTerms)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(restoring ? "Restoring…" : "Restore purchase") { Task { await restore() } }
                    .disabled(restoring)
                Spacer()
                Button("Terms of service") { openURL(AutocastLinks.terms) }
                Spacer()
                Button("Privacy policy") { openURL(AutocastLinks.privacy) }
            }
            .font(.footnote)
            .tint(.secondary)
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
    }

    private var closeButton: some View {
        Button {
            close()
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(Color(uiColor: .secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .padding(.trailing, 18)
        .accessibilityLabel("Close")
    }

    // MARK: - Words

    private func perMonth(_ yearly: Product) -> String {
        let monthlyEquivalent = yearly.price / 12
        return monthlyEquivalent.formatted(yearly.priceFormatStyle)
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

/// Six videos standing in a row, each its own colour, at slightly different
/// heights so it reads as a lineup and not a bar chart.
private struct LineupTiles: View {
    private let tiles: [(Color, String, CGFloat)] = [
        (.indigo, "calendar", -10),
        (.orange, "sparkles", 8),
        (.teal, "play.fill", -4),
        (.pink, "paperplane.fill", 10),
        (.green, "chart.bar.fill", -8),
        (.purple, "wand.and.stars", 4),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tile.0.gradient)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .overlay {
                        Image(systemName: tile.1)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .offset(y: tile.2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One fact in a small card, with the way to the full comparison under it.
private struct StatCard: View {
    enum Top {
        case text(String)
        case symbol(String)
    }

    let top: Top
    let label: String
    let compare: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Group {
                switch top {
                case .text(let text):
                    Text(text)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 26, weight: .semibold))
                }
            }
            .foregroundStyle(.primary)
            .frame(height: 36)

            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Button(action: compare) {
                Text("Compare")
                    .font(.caption)
                    .underline()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One plan: a band across the top when it is the one to pick, the name and
/// the yearly total on the left, the monthly figure and a check on the right.
private struct PlanCard: View {
    let band: String?
    let title: String
    let subtitle: String?
    let trailing: String
    let chosen: Bool
    let tap: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 0) {
                if let band {
                    Text(band)
                        .font(.caption.weight(.bold))
                        .kerning(1)
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Theme.accent)
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(band == nil ? .headline : .title2.bold())
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                    }

                    Spacer(minLength: 8)

                    Text(trailing)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(chosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(uiColor: .systemGray3)))
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(16)
            }
            .background(chosen ? Color(uiColor: .secondarySystemBackground) : Color(uiColor: .systemBackground))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(chosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(uiColor: .systemGray4)),
                                   lineWidth: chosen ? 2 : 1.5)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

// MARK: - Free against Pro

/// The comparison, on its own sheet: what both get, what only Pro gets.
private struct CompareSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Cell {
        case check
        case value(String)
        case blank
    }

    struct Row {
        let title: String
        let free: Cell
        let pro: Cell
    }

    private static let rows: [Row] = [
        .init(title: "Post to TikTok, YouTube and Instagram", free: .check, pro: .check),
        .init(title: "Approve every post before it goes out", free: .check, pro: .check),
        .init(title: "Make videos with your own generator", free: .check, pro: .check),
        .init(title: "Days planned ahead", free: .value("7"), pro: .value("30")),
        .init(title: "Captions and posts written for you each month", free: .value("5"), pro: .value("500")),
        .init(title: "Chat messages each month", free: .value("20"), pro: .value("1,000")),
        .init(title: "Accounts it posts to", free: .value("1"), pro: .value("5")),
        .init(title: "Support the development of Autocast and new features", free: .blank, pro: .check),
    ]

    private let freeWidth: CGFloat = 60
    private let proWidth: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            Text("Why should I get Autocast Pro?")
                .font(.headline)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Compare")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Free")
                            .font(.headline)
                            .frame(width: freeWidth)
                        Text("Pro")
                            .font(.headline)
                            .frame(width: proWidth)
                    }
                    .padding(.vertical, 16)

                    ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                        Divider()
                        HStack(spacing: 0) {
                            Text(row.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, 8)
                            cell(row.free)
                                .frame(width: freeWidth)
                            cell(row.pro)
                                .frame(width: proWidth)
                        }
                        .padding(.vertical, 15)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(row.title). Free: \(spoken(row.free)). Pro: \(spoken(row.pro)).")
                        .id(index)
                    }
                }
                // The Pro column, tinted the whole way down.
                .background(alignment: .trailing) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.track)
                        .frame(width: proWidth)
                        .padding(.vertical, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            Button {
                dismiss()
            } label: {
                Text("Got it 👌")
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemBackground))
        .presentationDetents([.fraction(0.8), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    @ViewBuilder
    private func cell(_ cell: Cell) -> some View {
        switch cell {
        case .check:
            Image(systemName: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        case .value(let text):
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        case .blank:
            Text("")
        }
    }

    private func spoken(_ cell: Cell) -> String {
        switch cell {
        case .check: "yes"
        case .value(let text): text
        case .blank: "no"
        }
    }
}
