import SwiftUI

/// The connect screen until an account is linked, then the queue.
struct QueueTabView: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                switch store.connectionState {
                case .disconnected, .connecting:
                    ConnectAccountView()
                case .connected:
                    PostListView()
                }
            }
        }
    }
}

#Preview("Disconnected") {
    QueueTabView()
        .environment(ContentStore())
}
