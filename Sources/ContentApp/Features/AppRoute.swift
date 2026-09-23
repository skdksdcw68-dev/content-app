import SwiftUI

/// The tabs, named. Shared by the shell and by the chrome each tab publishes.
enum AppTab: Hashable {
    case home, chat, analytics, you, create
}

/// Everywhere a tab's root can go by value.
///
/// Build 72 (22 Sep 2026) had one navigation stack around the tabs -- the
/// right shape, the Telegram push -- and the chat stopped opening. A
/// `navigationDestination` declared INSIDE a tab is not seen by a stack that
/// sits outside the `TabView`; the link fires and nothing happens. So the
/// destinations a tab root needs are declared once, on the tab shell itself,
/// keyed by this enum, and a root pushes by appending to the session's path.
/// Pages already on the stack keep their ordinary view-based links: they are
/// inside the stack, where those work.
enum AppRoute: Hashable {
    /// A saved conversation by id, or a fresh one.
    case chat(UUID?)
    /// A fresh conversation that starts by sending these words.
    case chatOpening(String)
    /// The plan, with the proposal that just made it when there is one.
    case plan(PlanProposal?)
    /// One post's detail page.
    case post(UUID)
    /// Every post, as a list.
    case library
}

// MARK: - Chrome from inside a tab

/// What a tab wants in the navigation bar over it.
///
/// The bar belongs to the stack around the tabs, and a `.toolbar` written
/// inside a tab never reaches it (Abel, build 72: "you removed all the top
/// things... the upgrade and profile thing, the left side things"). Each tab
/// root publishes its title and its bar items through this preference; the
/// shell reads the selected tab's entry and draws them where they belong.
struct TabChrome {
    /// How the title sits. `inlineLarge` is iOS 26's large title on the SAME
    /// line as the bar items -- Abel, 23 Sep 2026: "the good morning and the
    /// profile thing is not on the same line."
    /// `bare` is a bar with no title and no background: only the items
    /// float, and the screen draws its own heading that scrolls away.
    enum Mode { case large, inline, inlineLarge, hidden, bare }

    var title: String = ""
    var mode: Mode = .large
    var leading: AnyView?
    var trailing: AnyView?
}

struct TabChromeKey: PreferenceKey {
    static let defaultValue: [AppTab: TabChrome] = [:]
    static func reduce(value: inout [AppTab: TabChrome], nextValue: () -> [AppTab: TabChrome]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ChromeTabKey: EnvironmentKey {
    static let defaultValue: AppTab? = nil
}

extension EnvironmentValues {
    /// Which tab a root view is the root of, set by the shell.
    var chromeTab: AppTab? {
        get { self[ChromeTabKey.self] }
        set { self[ChromeTabKey.self] = newValue }
    }
}

extension View {
    /// A tab root's title and bar items, delivered to the shell. A side that
    /// is nil gets no item at all -- an empty toolbar item still draws its
    /// glass on iOS 26.
    func tabChrome(
        title: String,
        mode: TabChrome.Mode = .large,
        leading: AnyView? = nil,
        trailing: AnyView? = nil
    ) -> some View {
        modifier(TabChromeModifier(
            chrome: TabChrome(title: title, mode: mode, leading: leading, trailing: trailing)
        ))
    }
}

extension TabChrome.Mode {
    var system: ToolbarTitleDisplayMode {
        switch self {
        case .large:       .large
        case .inline:      .inline
        case .inlineLarge: .inlineLarge
        case .hidden:      .inline
        case .bare:        .inline
        }
    }
}

private struct TabChromeModifier: ViewModifier {
    let chrome: TabChrome
    @Environment(\.chromeTab) private var tab

    func body(content: Content) -> some View {
        content
            // Also set directly, for the case where the system does carry
            // them through; the shell's copy wins when it does not.
            .navigationTitle(chrome.title)
            .toolbarTitleDisplayMode(chrome.mode.system)
            .preference(key: TabChromeKey.self, value: tab.map { [$0: chrome] } ?? [:])
    }
}
