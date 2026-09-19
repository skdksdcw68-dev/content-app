import SwiftUI

/// The shell.
///
/// This is Apple's TabView, not a hand-drawn bar. The previous version was
/// custom because a detached Profile is something TabView cannot do -- and the
/// moment it shipped, it read as hand-made, which is exactly what a custom bar
/// always reads as. Detaching Profile was not worth that.
///
/// On iOS 26 the system bar floats over the content, blurs what is behind it,
/// and shrinks out of the way as you scroll down. All of that is free here and
/// impossible to reproduce convincingly by hand, which is the whole argument.
struct RootView: View {
    /// Named rather than positional, the way email-app does it. A selection
    /// binding is what lets anything outside the bar move between tabs -- an
    /// onboarding step finishing, a notification, a card on Home.
    private enum AppTab: Hashable { case home, chat, analytics, you, create }

    @Environment(AppSession.self) private var session
    @State private var tab: AppTab = .home
    /// Light unless the person chose otherwise (Remi's default). Read here, at
    /// the root, so the choice reaches every screen -- sheets included -- at once.
    @State private var appearance = AppAppearance.current

    var body: some View {
        @Bindable var session = session

        Group {
            switch session.state {
            case .starting:
                StartingView()
            case .failed(let reason):
                StartupFailedView(reason: reason) {
                    Task { await session.start() }
                }
            case .ready:
                // First run comes before the app, and only once. The step is
                // read from UserDefaults before any query resolves, so nobody
                // sees the tabs flash past on the way to the welcome screen.
                if session.onboarding == .done {
                    tabs
                } else {
                    OnboardingFlowView()
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: session.onboarding == .done)
        .tint(Theme.accent)
        .preferredColorScheme(appearance.colorScheme)
        // Every switch in the app, Remi's way: visible in light and dark.
        .toggleStyle(RemiSwitchStyle())
        .onReceive(NotificationCenter.default.publisher(for: .appearanceChanged)) { _ in
            appearance = AppAppearance.current
        }
        // A Pro limit anywhere opens Autocast Pro; the message that came with
        // it is the paywall's reason, not a second alert.
        .sheet(isPresented: $session.showingPaywall, onDismiss: { session.lastError = nil }) {
            PaywallView()
        }
        .task { await session.listenForTransactions() }
        .alert(
            "That did not work",
            isPresented: Binding(
                get: { session.lastError != nil && !session.showingPaywall },
                set: { if !$0 { session.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { session.lastError = nil }
        } message: {
            Text(session.lastError ?? "")
        }
    }

    private var tabs: some View {
        // Filled symbols and a selection binding, matching email-app. The
        // outlined variants read as lighter than the bar they sit in, which is
        // why every Apple app uses the filled ones here.
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack { HomeView() }
            }

            // The one tab that hides the bar it lives in.
            //
            // Not a preference. The composer is pinned to the bottom of the
            // screen by UIKit, through the keyboard's own frame -- it does not
            // know the tab bar exists and cannot be told, because the whole
            // reason it is done that way is that SwiftUI's layout was too slow
            // to keep up with the keyboard. Two things owning the bottom edge
            // means the send button sits behind the bar.
            //
            // A conversation is a place you are *in* rather than a section you
            // are browsing, which is why it takes the full screen and hides the
            // bar. But the TAB is not a conversation -- it used to open
            // straight into whichever chat was in memory, so there was no way
            // back to an earlier one and no obvious way to start a fresh one.
            //
            // So the tab is the list, where the bar belongs because browsing is
            // browsing, and a conversation is presented over it. The bar hides
            // only once you are inside one.
            Tab("Chat", systemImage: "sparkles", value: AppTab.chat) {
                NavigationStack { ChatListView() }
            }

            // Analytics took Library's place (Abel, 15 Sep 2026). The full post
            // list is still one tap away, at the bottom of Analytics.
            Tab("Analytics", systemImage: "chart.bar.fill", value: AppTab.analytics) {
                NavigationStack { AnalyticsView() }
            }

            // The badge is where Home's warnings went. A native count on the
            // tab, not a red box on the first screen -- and not nothing,
            // because a failure nobody sees is how September happened.
            Tab("You", systemImage: "person.crop.circle.fill", value: AppTab.you) {
                NavigationStack { ProfileView() }
            }
            .badge(session.attentionCount)

            // The detached one, sitting in its own circle beside the bar.
            //
            // `.search` is the only role iOS 26 detaches, and it is the reason
            // the previous version of this app hand-built a tab bar and then
            // read as hand-built. This gets the same shape from the system: the
            // pill keeps four tabs, the plus floats to its right, and all the
            // Liquid Glass behaviour comes free.
            //
            // Semantically it is the search slot, which is a stretch. It takes
            // a custom icon and shows whatever content it is given rather than
            // forcing a search field, so the stretch is in the name and not in
            // the behaviour. If a future iOS insists on a search field here,
            // the fallback is `.tabViewBottomAccessory` with a Create pill --
            // a different shape, same job, still native.
            Tab("Create", systemImage: "plus", value: AppTab.create, role: .search) {
                NavigationStack { CreateView() }
            }
        }
        // 🔴 `.tabBarMinimizeBehavior(.onScrollDown)` was here, and it is gone
        // because Abel hated it -- correctly. It is a genuinely good iOS 26
        // behaviour for a reading app, where the content is the point and the
        // chrome is in the way. This is a control centre: the bar is how you
        // move between the four things the product does, and a bar that
        // disappears while you scroll a status page makes you scroll back up
        // to reach it. Free from the system is not a reason to take it.
    }
}

/// The mark, alone, fading in -- Remi's splash (`Onboarding/SplashView.swift`):
/// scale from 0.92 as it appears over 0.55s. No spinner, no words.
private struct StartingView: View {
    @State private var shown = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            TowerMark()
                .frame(width: 96, height: 96)
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown ? 1 : 0.92)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) { shown = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Getting things ready")
    }
}

/// Says what went wrong and offers the only useful action, rather than leaving
/// a spinner turning forever.
private struct StartupFailedView: View {
    let reason: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Could not reach Netro Autocast")
                .font(.headline)

            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Try again", action: retry)
                .buttonStyle(RemiFilledButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}
