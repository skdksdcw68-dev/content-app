import SwiftUI
import UIKit

/// Signing out: the splash over EVERYTHING on the screen -- the Settings sheet
/// and the app under it -- from the moment Sign Out is confirmed, looping until
/// the account is let go and the welcome is ready, then the P opens into it.
///
/// Abel, 8 Nov 2026: the splash played inside the sheet only, and after the
/// sheet closed the Home screen stayed up for a moment before anything
/// happened. A view in the app cannot draw over a presented sheet, so this is
/// its own window above the app's, the way the system draws an alert.
@MainActor
enum SignOutCover {
    private static var window: UIWindow?

    /// True while the cover is up. The root's own launch splash stays away
    /// meanwhile, or two splashes would open one inside the other.
    static var isShowing: Bool { window != nil }

    static func show(over session: AppSession) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.backgroundColor = .clear
        let host = UIHostingController(rootView: SignOutSplash(session: session) { hide() })
        host.view.backgroundColor = .clear
        cover.rootViewController = host
        cover.isHidden = false
        window = cover
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// The splash, fading in over whatever is on screen (0.35 s, as the mockup),
/// then the same loop as the launch splash until the session has started over.
private struct SignOutSplash: View {
    let session: AppSession
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    /// The session has gone back to `.starting`: the old account is let go.
    @State private var leftAccount = false

    var body: some View {
        LaunchSplash(ready: leftAccount && session.state != .starting, finished: done)
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 1.04)
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.35)) { shown = true }
            }
            .onChange(of: session.state) { _, state in
                if state == .starting { leftAccount = true }
            }
            // Never a screen that cannot be left: if the sign-out somehow
            // never restarts the session, the splash still opens.
            .task {
                try? await Task.sleep(for: .seconds(20))
                leftAccount = true
            }
    }
}
