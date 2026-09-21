import SwiftUI
import UIKit

// Remi's PushedPage, copied whole (remi/native/Sources/Remi/Views/PushedPage.swift)
// on 21 Sep 2026 after removing the SwiftUI switch here stopped the bar hiding
// at all. Remi settled this already: the switch is unconditional because it
// cannot miss, and the UIKit flag rides on top because it is what slides.

// MARK: - Pushed pages

extension View {
    /// A page pushed onto a tab's stack: the tab bar goes with it.
    ///
    /// The owner, twice: "when you go to your profile and click the
    /// notification and you leave it back, the way the bottom navs appear is
    /// so bad... they just got removed or hidden for the moment, not covered
    /// I think." Which is exactly what was happening. SwiftUI's
    /// `toolbar(.hidden, for: .tabBar)` is a switch: the bar is there, then
    /// it is not, then it is there again. It blinks out as the page slides
    /// in and blinks back before the page has finished sliding out, so the
    /// bar reads as being deleted and recreated rather than as leaving.
    ///
    /// UIKit has had the right behaviour since the first iPhone:
    /// `hidesBottomBarWhenPushed` on the controller being pushed. The
    /// navigation controller reads it while it sets the push up, slides the
    /// bar off the bottom inside the same animation as the page, slides it
    /// back inside the pop, and -- the part no switch can imitate -- tracks
    /// a swipe-back finger for finger, putting the bar back where it was if
    /// the swipe is abandoned halfway. That is what this asks for.
    ///
    /// It asks through a marker: a controller that draws nothing, sits in
    /// the page's background, and on being added to the view controller
    /// hierarchy walks up its own `parent` chain to the page it is inside
    /// and sets the flag there. If it cannot find one -- a layout SwiftUI
    /// hosts some way this does not recognise -- the old switch takes over,
    /// so a page can never be left with the tab bar sitting on top of it.
    ///
    /// Every `navigationDestination` in the app wraps its screen in this.
    func pushedPage() -> some View {
        modifier(PushedPage())
    }

    /// The older name, kept so existing call sites read the same.
    func hidesTabBar() -> some View {
        pushedPage()
    }
}

/// Both ways of taking the tab bar away, together.
///
/// 🔴 The first attempt used the UIKit flag *instead of* the SwiftUI switch,
/// and only fell back to the switch if the marker reported finding nothing
/// to mark. It reported success and the bar stayed anyway -- the controller
/// it found was some hosting container inside the page rather than the page
/// UIKit pushes, so the flag had no effect and the fallback never ran. The
/// owner, on that build: "Now its everywhere."
///
/// So the switch is unconditional: the bar is hidden on a pushed page,
/// always, by the one mechanism that cannot miss. The UIKit flag is still
/// set on top of it, because when it does land it is what makes the bar
/// *slide* with the push and track a swipe-back finger for finger. Both say
/// the same thing, so there is nothing for them to disagree about.
struct PushedPage: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .tabBar)
            // Behind the page, drawing nothing and catching nothing: the
            // marker's own view is hidden and deaf, so it costs a rectangle
            // in the hierarchy and no pixels.
            .background {
                HidesBottomBarWhenPushed()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

// MARK: - The UIKit side

/// Puts a marker controller into the page, which asks UIKit for the slide.
private struct HidesBottomBarWhenPushed: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BottomBarMarker {
        BottomBarMarker()
    }

    func updateUIViewController(_ marker: BottomBarMarker, context: Context) {
        // `willMove(toParent:)` is normally where this lands; this is only
        // for the order where SwiftUI attaches the child before it updates.
        marker.claim(from: marker.parent)
    }
}

/// A controller that draws nothing and exists to say one thing to UIKit.
private final class BottomBarMarker: UIViewController {
    /// The guard against doing it twice: the flag is set on exactly one
    /// controller, once, whichever of the hooks below gets there first.
    private var marked = false

    override func loadView() {
        let empty = UIView(frame: .zero)
        empty.isHidden = true
        empty.isUserInteractionEnabled = false
        view = empty
    }

    // The earliest moment there is a chain to walk. `self.parent` is still
    // nil here -- it is set after this returns -- so the chain is walked
    // from the parent UIKit is handing over, which is the whole reason this
    // hook is used: `hidesBottomBarWhenPushed` has to be true before the
    // navigation controller sets the push up, not after.
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

    /// Marks the page this marker sits inside, once.
    func claim(from start: UIViewController?) {
        guard !marked, let page = Self.enclosingPage(above: start) else { return }
        marked = true
        // A page that already hides the bar -- two `.pushedPage()`s on one
        // screen, or a page pushed on top of one that already hid it -- is
        // left exactly as it is.
        if !page.hidesBottomBarWhenPushed {
            page.hidesBottomBarWhenPushed = true
        }
    }

    /// The pushed page above this marker: the outermost controller over it
    /// that is not itself a container. Before the push that is the page's
    /// own hosting controller, sitting at the top of the chain with no
    /// parent yet; after it, the same controller, with the navigation
    /// controller above it. Either way it is the one UIKit reads the flag
    /// from.
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
