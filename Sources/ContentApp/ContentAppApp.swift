import SwiftUI
import TipKit
import UIKit

@main
struct ContentAppApp: App {
    /// One session for the whole app: the Supabase client, the signed-in user,
    /// the brand and its connected accounts. Signing in happens on launch, so
    /// the first screen is the product rather than a login wall.
    @State private var session = AppSession()

    init() {
        #if DEBUG
        // Screenshots: no tip popovers over the screens.
        if UserDefaults.standard.string(forKey: "demoEmail") != nil { Tips.hideAllTipsForTesting() }
        #endif
        AppTips.configure()
        if Self.paywallPreview || Self.welcomePreview || Self.launchedWith("-subscriberPreview") { Self.seedPreviewPrices() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if Self.launchedWith("-composerPreview") {
                    ComposerPreview()
                } else if Self.launchedWith("-autopilotPreview") {
                    // Only once signed in: these read the account as soon as they appear.
                    if session.state == .ready { NavigationStack { AutopilotView() } } else { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
                } else if Self.launchedWith("-usagePreview") {
                    if session.state == .ready { NavigationStack { UsageView() } } else { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
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
                    Task { await Self.scrollForStoreShots() }
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
            note = "signed in: \(result.user.id)"
        } catch {
            note = "sign-in failed: \(error)"
        }
        let url = URL.documentsDirectory.appending(path: "demo-status.txt")
        try? note.write(to: url, atomically: true, encoding: .utf8)
        #endif
    }

    /// Scrolls the biggest scroll view on screen to a given offset, so the part
    /// of a long screen that matters is the part photographed (-scrollOffset 700
    /// -scrollAfter 20). Debug only.
    static func scrollForStoreShots() async {
        #if DEBUG
        let defaults = UserDefaults.standard
        let offset = defaults.double(forKey: "scrollOffset")
        guard offset > 0 else { return }
        let after = defaults.double(forKey: "scrollAfter")
        try? await Task.sleep(for: .seconds(after > 0 ? after : 22))
        await MainActor.run {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return }
            var best: UIScrollView?
            func walk(_ view: UIView) {
                if let scroll = view as? UIScrollView, scroll.bounds.width > 300, scroll.contentSize.height > scroll.bounds.height + 50 {
                    if best == nil || scroll.contentSize.height > best!.contentSize.height { best = scroll }
                }
                view.subviews.forEach(walk)
            }
            walk(window)
            if let scroll = best {
                let top = -scroll.adjustedContentInset.top
                let limit = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: 0, y: min(top + offset, limit)), animated: false)
            }
        }
        #endif
    }

    /// And the one conversation to open, when asked (-openThread <id>).
    static func openForStoreShots(_ session: AppSession) async {
        #if DEBUG
        let defaults = UserDefaults.standard
        try? await Task.sleep(for: .seconds(1))
        if let raw = defaults.string(forKey: "openThread"), let id = UUID(uuidString: raw) {
            session.push(.chat(id))
        } else if let raw = defaults.string(forKey: "openPost"), let id = UUID(uuidString: raw) {
            session.push(.post(id))
        } else if let route = defaults.string(forKey: "openRoute") {
            switch route {
            case "generated": session.push(.generated)
            case "library": session.push(.library)
            case "inspiration": session.push(.inspiration)
            case "plan": session.push(.plan(nil))
            default: break
            }
        }
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
