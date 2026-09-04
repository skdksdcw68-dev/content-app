import SwiftUI

@main
struct ContentAppApp: App {
    /// One store for the whole app, owned here and handed down through the
    /// environment. Starts disconnected -- the first screen is the connect
    /// screen until an account is linked.
    @State private var store = ContentStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}
