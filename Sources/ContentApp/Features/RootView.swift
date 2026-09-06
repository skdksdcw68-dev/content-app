import SwiftUI

/// The shell: four surfaces and a hand-built bar.
///
/// All four are kept alive in a ZStack rather than swapped, so each keeps its
/// own scroll position and navigation stack across a tab change. That is one of
/// the two things TabView gives away free and a custom bar has to earn.
struct RootView: View {
    @Environment(AppSession.self) private var session
    @State private var tab: AppTab = .home
    /// Bumped when the active tab is tapped again; each surface watches its own
    /// counter and scrolls itself to the top.
    @State private var reselects: [AppTab: Int] = [:]

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
                shell
            }
        }
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

    private var shell: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                surface(.home) { HomeView(scrollToTop: reselects[.home] ?? 0) }
                surface(.chat) { ChatView() }
                surface(.library) { LibraryView() }
                surface(.profile) { ProfileView() }
            }

            TabBar(
                selection: $tab,
                onReselect: { reselects[$0, default: 0] += 1 },
                avatarURL: session.connections.first?.avatarURL,
                badge: 0
            )
            .padding(.bottom, 8)
        }
    }

    /// Hidden rather than removed. `.opacity` plus `allowsHitTesting` keeps the
    /// view's state alive; an `if` would rebuild it from scratch every time.
    @ViewBuilder
    private func surface<Content: View>(
        _ which: AppTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
        }
        .opacity(tab == which ? 1 : 0)
        .allowsHitTesting(tab == which)
        .accessibilityHidden(tab != which)
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
        .background(Color(.systemGroupedBackground))
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
        .background(Color(.systemGroupedBackground))
    }
}
