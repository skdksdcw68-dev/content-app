import SwiftUI
import UIKit

extension View {
    /// Hides the tab bar for this screen the way UIKit's
    /// `hidesBottomBarWhenPushed` always did: the bar slides away with the
    /// push and slides back with the pop, instead of vanishing in one frame.
    ///
    /// SwiftUI's own tab-bar hiding removes the bar with no animation at
    /// all, which reads as a glitch rather than a transition.
    /// On iOS 18 UIKit finally exposes `setTabBarHidden(_:animated:)`, and
    /// SwiftUI's TabView is a UITabBarController underneath, so a hidden
    /// helper controller can drive it from the pushed screen's appearance
    /// callbacks. Anything older keeps the abrupt SwiftUI behaviour -- worse,
    /// but never wrong.
    func hidesTabBar() -> some View {
        modifier(TabBarHidden())
    }
}

private struct TabBarHidden: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.background(TabBarSlider())
        } else {
            content.toolbar(.hidden, for: .tabBar)
        }
    }
}

/// An invisible child view controller that rides along with the pushed
/// screen. Child controllers receive their parent's appearance callbacks,
/// which fire *during* the navigation transition -- exactly when the bar has
/// to start moving for the slide to line up with the push.
@available(iOS 18.0, *)
private struct TabBarSlider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            tabBarController?.setTabBarHidden(true, animated: animated)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Popping back to a screen that wants the bar. When the *next*
            // screen also hides it (detail pushed over detail), its own
            // viewWillAppear runs within the same transition and re-hides;
            // the two calls coalesce without a visible flicker.
            tabBarController?.setTabBarHidden(false, animated: animated)
        }
    }
}
