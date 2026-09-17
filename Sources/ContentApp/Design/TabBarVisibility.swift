import SwiftUI
import UIKit

// Remi's `pushedPage()` (remi/native/Sources/Remi/Views/PushedPage.swift),
// brought across on 17 Sep 2026 after Abel: "doesn't hide the bottom navs right
// after, like on the profile". The version here before this set
// `setTabBarHidden` in `viewWillAppear`, which runs once the push has already
// started -- so the bar sat there for a beat and then went, and screens pushed
// without it (Profile, the plan, the library) kept the bar the whole time.

extension View {
    /// A page pushed onto a tab's stack: the tab bar goes with it.
    ///
    /// Two mechanisms, together. SwiftUI's `toolbar(.hidden, for: .tabBar)` is
    /// the one that cannot miss. UIKit's `hidesBottomBarWhenPushed`, set on the
    /// page before the navigation controller sets the push up, is what makes
    /// the bar slide away inside the same animation as the page and track a
    /// swipe-back finger for finger. Both say the same thing.
    ///
    /// Only on screens that are pushed. A screen that is also a tab's root
    /// (Create, You, Analytics) gets it where it is pushed, not in its body.
    func pushedPage() -> some View {
        modifier(PushedPage())
    }

    /// The older name, kept so existing call sites read the same.
    func hidesTabBar() -> some View {
        pushedPage()
    }
}

private struct PushedPage: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .tabBar)
            .background {
                HidesBottomBarWhenPushed()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// Puts a marker controller into the page, which asks UIKit for the slide.
private struct HidesBottomBarWhenPushed: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BottomBarMarker {
        BottomBarMarker()
    }

    func updateUIViewController(_ marker: BottomBarMarker, context: Context) {
        marker.claim(from: marker.parent)
    }
}

/// A controller that draws nothing and exists to say one thing to UIKit.
private final class BottomBarMarker: UIViewController {
    private var marked = false

    override func loadView() {
        let empty = UIView(frame: .zero)
        empty.isHidden = true
        empty.isUserInteractionEnabled = false
        view = empty
    }

    // The earliest moment there is a chain to walk: the flag has to be set
    // before the navigation controller sets the push up, not after.
    override func willMove(toParent parent: UIViewController?) {
        super.willMove(toParent: parent)
        claim(from: parent)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        claim(from: parent)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        claim(from: parent)
    }

    func claim(from start: UIViewController?) {
        guard !marked, let page = Self.enclosingPage(above: start) else { return }
        marked = true
        if !page.hidesBottomBarWhenPushed {
            page.hidesBottomBarWhenPushed = true
        }
    }

    /// The outermost controller above the marker that is not a container:
    /// the page UIKit pushes, and reads the flag from.
    private static func enclosingPage(above start: UIViewController?) -> UIViewController? {
        var found: UIViewController?
        var step = start
        while let candidate = step {
            if candidate is UINavigationController
                || candidate is UITabBarController
                || candidate is UISplitViewController {
                break
            }
            found = candidate
            step = candidate.parent
        }
        return found
    }
}
