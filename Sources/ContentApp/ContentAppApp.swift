import SwiftUI
import UIKit

@main
struct ContentAppApp: App {
    /// One session for the whole app: the Supabase client, the signed-in user,
    /// the brand and its connected accounts. Signing in happens on launch, so
    /// the first screen is the product rather than a login wall.
    @State private var session = AppSession()

    init() {
        AppTips.configure()
        if Self.paywallPreview || Self.welcomePreview || Self.launchedWith("-subscriberPreview") { Self.seedPreviewPrices() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if Self.launchedWith("-composerPreview") {
                    ComposerPreview()
                } else if Self.launchedWith("-autopilotPreview") {
                    NavigationStack { AutopilotView() }
                } else if Self.launchedWith("-usagePreview") {
                    NavigationStack { UsageView() }
                } else if Self.launchedWith("-introPreview") {
                    HomeIntroView {}
                } else if Self.launchedWith("-profilePreview") {
                    EditProfileView()
                } else if Self.launchedWith("-subscriberPreview") {
                    PaywallView()
                } else if Self.welcomePreview {
                    PaywallView(previewWelcome: .max)
                } else if Self.editorPreview {
                    NavigationStack { EditorView(clips: [Self.previewClip()], ownsBackButton: true) }
                } else if Self.paywallPreview {
                    PaywallView()
                } else {
                    RootView()
                }
            }
            .environment(session)
            .task {
                if Self.launchedWith("-subscriberPreview") {
                    // Pro, as a subscriber sees it: the status page and the
                    // way up, never "Subscribe to Pro".
                    session.previewAsSubscriber()
                    await session.loadPlanTiers()
                    await session.loadProducts()
                } else if Self.welcomePreview || Self.editorPreview {
                    await session.loadPlanTiers()
                } else if Self.paywallPreview {
                    await session.loadPlanTiers()
                    await session.loadProducts()
                } else {
                    await Self.signInForStoreShots(session)
                    await session.start()
                    await Self.openForStoreShots(session)
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
    /// App Store screenshots: a Debug simulator build can sign in to the demo
    /// account from tokens handed over on the command line (-demoAccess,
    /// -demoRefresh), so the real screens are photographed with real data.
    /// Compiled out of Release.
    static func signInForStoreShots(_ session: AppSession) async {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard let email = defaults.string(forKey: "demoEmail"),
              let password = defaults.string(forKey: "demoPassword") else { return }
        // Written where the lane can read it: whether the sign-in worked, and
        // if not, why. (-demoEmail / -demoPassword: a throwaway demo account.)
        var note = ""
        do {
            let result = try await session.client.auth.signIn(email: email, password: password)
            note = "signed in: (result.user.id)"
        } catch {
            note = "sign-in failed: (error)"
        }
        let url = URL.documentsDirectory.appending(path: "demo-status.txt")
        try? note.write(to: url, atomically: true, encoding: .utf8)
        #endif
    }

    /// And the one conversation to open, when asked (-openThread <id>).
    static func openForStoreShots(_ session: AppSession) async {
        #if DEBUG
        guard let raw = UserDefaults.standard.string(forKey: "openThread"),
              let id = UUID(uuidString: raw) else { return }
        try? await Task.sleep(for: .seconds(1))
        session.push(.chat(id))
        #endif
    }

    /// The paywall on its own, for App Store Connect's review screenshot: every
    /// subscription needs one, and the `ios-paywall-shot` lane launches a
    /// simulator build with `-paywallPreview` and photographs it. Debug builds
    /// only, so nothing shipped can be opened this way.
    static var paywallPreview: Bool { launchedWith("-paywallPreview") }

    /// The welcome after a purchase, and the editor opened the way chat opens
    /// it, for the same lane to photograph (18 Oct 2026).
    static var welcomePreview: Bool { launchedWith("-welcomePreview") }
    static var editorPreview: Bool { launchedWith("-editorPreview") }

    static func launchedWith(_ argument: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(argument)
        #else
        false
        #endif
    }

    /// A picture to edit, drawn here: the simulator has no photo library.
    static func previewClip() -> StudioClip {
        let size = CGSize(width: 1080, height: 1920)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-clip.jpg")
        try? image.jpegData(compressionQuality: 0.9)?.write(to: url)
        return .photo(url)
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

/// The chat composer at rest with the Create video pill, and the research
/// indicator above it, for the screenshot lane. Launched with -composerPreview.
private struct ComposerPreview: View {
    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    ShimmerText(text: "Researching…")
                }
                .padding(.horizontal, 20)
                Spacer()
                ChatComposer(
                    text: .constant(""),
                    showsOptions: .constant(false),
                    isWorking: false,
                    resetToken: 0,
                    focusToken: 0,
                    onCreateVideo: {},
                    onSend: {},
                    onStop: {}
                )
                .padding(.bottom, 24)
            }
            .padding(.top, 120)
        }
    }
}
