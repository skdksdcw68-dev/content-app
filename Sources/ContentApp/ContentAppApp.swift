import SwiftUI

@main
struct ContentAppApp: App {
    /// One session for the whole app: the Supabase client, the signed-in user,
    /// the brand and its connected accounts. Signing in happens on launch, so
    /// the first screen is the product rather than a login wall.
    @State private var session = AppSession()

    init() {
        AppTips.configure()
        if Self.paywallPreview { Self.seedPreviewPrices() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if Self.paywallPreview {
                    PaywallView()
                } else {
                    RootView()
                }
            }
            .environment(session)
            .task {
                if Self.paywallPreview {
                    await session.loadPlanTiers()
                    await session.loadProducts()
                } else {
                    await session.start()
                }
            }
            // Google hands its result back through the reversed-client-id
            // scheme in Info.plist. Anything on our own `autocast` scheme
            // is an OAuth callback the WebAuth sheet is already waiting
            // for, so it is left alone.
            .onOpenURL { url in
                guard url.scheme != Config.callbackScheme else { return }
                GoogleAuth.handle(url)
            }
        }
    }
}

private extension ContentAppApp {
    /// The paywall on its own, for App Store Connect's review screenshot: every
    /// subscription needs one, and the `ios-paywall-shot` lane launches a
    /// simulator build with `-paywallPreview` and photographs it. Debug builds
    /// only, so nothing shipped can be opened this way.
    static var paywallPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-paywallPreview")
        #else
        false
        #endif
    }

    /// The approved US prices (Netro, 2 Oct 2026), for a simulator that has
    /// no App Store account to ask. Real StoreKit prices replace them the
    /// moment StoreKit answers.
    static func seedPreviewPrices() {
        guard RememberedPricing.saved == nil else { return }
        RememberedPricing(
            prices: [
                "autocast.pro.monthly": "$29.99",
                "autocast.pro.yearly": "$249.99",
                "autocast.max.monthly": "$79.99",
                "autocast.max.yearly": "$649.99",
                "autocast.ultra.monthly": "$199.99",
            ],
            currency: "USD"
        ).save()
    }
}
