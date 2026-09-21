import SwiftUI

@main
struct ContentAppApp: App {
    /// One session for the whole app: the Supabase client, the signed-in user,
    /// the brand and its connected accounts. Signing in happens on launch, so
    /// the first screen is the product rather than a login wall.
    @State private var session = AppSession()

    init() {
        AppTips.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task { await session.start() }
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
