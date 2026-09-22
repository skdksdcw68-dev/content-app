import SwiftUI

// MARK: - Pushed pages

extension View {
    /// A page pushed onto the app's stack.
    ///
    /// This used to be the whole problem. Every tab had its own
    /// `NavigationStack`, so a pushed page lived INSIDE the tab and the tab
    /// bar was part of its hierarchy; the only thing this modifier could do
    /// was switch the bar off (`toolbar(.hidden, for: .tabBar)`), with a
    /// UIKit `hidesBottomBarWhenPushed` marker on top that landed sometimes.
    /// Abel, 22 Sep 2026, against Telegram side by side: "the navigation is
    /// just disappearing when you open another page."
    ///
    /// Now there is one stack around the `TabView` (see `RootView`). A pushed
    /// page is pushed over the whole tab shell, bar included, so the bar
    /// stays on the screen underneath and slides with it during a swipe
    /// back -- UIKit's own transition, nothing switched. There is nothing
    /// left for this modifier to do, and it does nothing; it is kept so the
    /// eighty call sites keep reading as what they are.
    func pushedPage() -> some View {
        self
    }

    /// The older name, kept so existing call sites read the same.
    func hidesTabBar() -> some View {
        pushedPage()
    }
}
