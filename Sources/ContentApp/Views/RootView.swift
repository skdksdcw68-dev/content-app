import SwiftUI

/// The four primary destinations.
///
/// Create is deliberately not among them. It is an action, not a place, and
/// giving it a tab would both weaken it and spend a navigation slot on
/// something that never has a screen of its own to return to.
enum AppTab: Hashable {
    case home
    case plan
    case insights
    case profile
}

/// Four tabs and one raised action.
///
/// Home is where the day is; Plan is the calendar; Insights is what happened;
/// Profile is who this account is and what it is allowed to do. Everything
/// else is reachable from inside one of them.
struct RootView: View {
    @Environment(ContentStore.self) private var store
    @State private var selection: AppTab = .home
    @State private var isShowingCreate = false

    var body: some View {
        Group {
            switch store.connectionState {
            case .disconnected, .connecting:
                // All four tabs would be empty without an account, so the
                // connect screen stands in front of them rather than hiding
                // inside one and letting the other three look broken.
                NavigationStack { ConnectAccountView() }
            case .connected:
                tabs
            }
        }
        .tint(Theme.accent)
        // Every refusal in the store -- a move into quiet hours, generating
        // with nothing connected -- lands here. Without this the app silently
        // does nothing and looks broken.
        .alert(
            "That did not work",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            HomeView(onCreate: { isShowingCreate = true })
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)

            PlanView()
                .tabItem { Label("Plan", systemImage: "calendar") }
                .tag(AppTab.plan)
                // The badge goes here rather than on Home: what waits on a
                // person is always something with a slot already booked.
                .badge(store.awaitingApprovalCount)

            InsightsView()
                .tabItem { Label("Insights", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(AppTab.insights)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
        .overlay(alignment: .bottomTrailing) {
            CreateButton { isShowingCreate = true }
                .padding(.trailing, 20)
                // Clear of the tab bar rather than overlapping it, so it never
                // sits on top of a tab label and swallow its taps.
                .padding(.bottom, 60)
        }
        .sheet(isPresented: $isShowingCreate) {
            CreateMenu()
        }
    }
}

/// The strongest action in the app, raised clear of the tab bar.
///
/// Circular and accent-filled because it is the only control in the app that
/// looks like this -- everything else is a native surface, which is what makes
/// one accent-coloured circle read as "the thing to press".
struct CreateButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(width: 58, height: 58)
                .background(Theme.accent, in: Circle())
                .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create")
        .accessibilityHint("Make a video, post, or campaign, or ask the AI for something")
    }
}

#Preview("Connected") {
    let store = ContentStore()
    return RootView()
        .environment(store)
        .task { await store.connect() }
}

#Preview("First run") {
    RootView()
        .environment(ContentStore())
}
