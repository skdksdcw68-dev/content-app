import SwiftUI
import StoreKit

/// Autocast Pro.
///
/// Apple's own subscription store view: the prices, the trial wording, the
/// renewal terms and Restore are drawn by StoreKit from what is set up in App
/// Store Connect, in every language and currency, and always say exactly what
/// Apple will charge. Our part is the reason to subscribe above it.
///
/// Every line in the list is a real, enforced difference (plans_catalog,
/// migration 0051) -- nothing here promises results.
struct PaywallView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SubscriptionStoreView(productIDs: AppSession.proProductIDs) {
            VStack(spacing: 18) {
                TowerMark()
                    .frame(width: 56, height: 56)
                    .padding(.top, 8)

                VStack(spacing: 6) {
                    Text("Autocast Pro")
                        .font(.largeTitle.weight(.bold))
                    Text("Your whole month of content, planned and posted.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Perk(symbol: "calendar", title: "Plan the whole month", detail: "30-day plans instead of a week at a time.")
                    Perk(symbol: "sparkles", title: "500 AI caption writes", detail: "Every month, instead of 5.")
                    Perk(symbol: "bubble.left.and.text.bubble.right", title: "1,000 chat messages", detail: "Every month, instead of 20.")
                    Perk(symbol: "person.2", title: "Up to 5 accounts", detail: "Instead of 1.")
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 8)
        }
        .subscriptionStoreControlStyle(.prominentPicker)
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.hidden, for: .cancellation)
        .subscriptionStorePolicyDestination(url: AutocastLinks.terms, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: AutocastLinks.privacy, for: .privacyPolicy)
        // The purchase is bound to this Autocast user, so the server can
        // refuse a receipt bought by somebody else.
        .inAppPurchaseOptions { _ in
            guard let userID = session.userID else { return [] }
            return [.appAccountToken(userID)]
        }
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success(let verification)) = result {
                await session.completePurchase(verification)
                if session.subscription?.isPro == true { dismiss() }
            }
        }
        .tint(Theme.accent)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("Close")
        }
        .task { await session.refreshSubscription() }
    }
}

private struct Perk: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIcon(symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
