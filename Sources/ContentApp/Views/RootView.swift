import SwiftUI

/// The four tabs.
///
/// Create earns a slot because it is a place you go and think in, not a control
/// you poke on the way past -- and a stock tab bar with four evenly spaced
/// items is the whole chrome budget. Insights is not here: it reads as a
/// summary on Home and opens in full from there, which is how often anyone
/// actually needs it.
enum AppTab: Hashable {
    case home
    case plan
    case create
    case profile
}

struct RootView: View {
    @Environment(ContentStore.self) private var store
    @State private var selection: AppTab = .home

    var body: some View {
        Group {
            switch store.connectionState {
            case .disconnected, .connecting:
                OnboardingView()
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
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)

            PlanView()
                .tabItem { Label("Plan", systemImage: "calendar") }
                .tag(AppTab.plan)
                // What waits on a person is always something with a slot
                // already booked, so the badge belongs on the calendar.
                .badge(store.awaitingApprovalCount)

            // Asking for something and then being left on an empty form reads
            // as though nothing happened, so a successful request moves you to
            // the calendar it landed in.
            CreateView(onCreated: { selection = .plan })
                .tabItem { Label("Create", systemImage: "sparkles") }
                .tag(AppTab.create)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
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
