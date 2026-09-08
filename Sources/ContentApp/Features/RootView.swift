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
    private enum AppTab: Hashable { case home, chat, library, you, create }

    @Environment(AppSession.self) private var session
    @State private var tab: AppTab = .home

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
        .alert(
            "That did not work",
            isPresented: Binding(
                get: { session.lastError != nil },
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

            Tab("Chat", systemImage: "sparkles", value: AppTab.chat) {
                NavigationStack { ChatView() }
            }

            Tab("Library", systemImage: "square.grid.2x2.fill", value: AppTab.library) {
                NavigationStack { LibraryView() }
            }

            Tab("You", systemImage: "person.crop.circle.fill", value: AppTab.you) {
                NavigationStack { ProfileView() }
            }

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
        // The bar gets out of the way when reading and comes back on the way
        // up. Behaviour the system owns; asking for it is the whole cost.
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

private struct StartingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Getting things ready")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
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
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}
