import SwiftUI

/// Two tabs, deliberately. An autopilot that needs a five-tab app to supervise
/// is not an autopilot -- there is the queue it produced, and the rules it
/// works under.
struct RootView: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        TabView {
            QueueTabView()
                .tabItem {
                    Label("Queue", systemImage: "square.stack")
                }
                .badge(store.awaitingApprovalCount)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    RootView()
        .environment(ContentStore())
}
