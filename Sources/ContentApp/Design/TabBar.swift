import SwiftUI

/// The four destinations. Profile is deliberately not in the same group as the
/// others -- it is who you are rather than somewhere you work.
enum AppTab: String, CaseIterable, Hashable {
    case home, chat, library, profile

    var title: String {
        switch self {
        case .home:    return "Home"
        case .chat:    return "Chat"
        case .library: return "Library"
        case .profile: return "You"
        }
    }

    var symbolName: String {
        switch self {
        case .home:    return "house.fill"
        case .chat:    return "bubble.left.fill"
        case .library: return "square.grid.2x2.fill"
        case .profile: return "person.fill"
        }
    }

    /// The three that sit together in the capsule.
    static var grouped: [AppTab] { [.home, .chat, .library] }
}

/// A hand-built tab bar: three items in a capsule, and Profile detached beside
/// it as an avatar.
///
/// SwiftUI's own TabView spaces its items evenly and gives no way to pull one
/// out, and the floating bar on newer iOS reserves its detached slot for the
/// search role specifically. So the bar is drawn here, and the two behaviours
/// that come free with TabView -- a live navigation stack per tab, and
/// re-tapping the active tab to scroll to top -- are added back deliberately.
struct TabBar: View {
    @Binding var selection: AppTab
    /// Fires when the already-selected tab is tapped again.
    var onReselect: (AppTab) -> Void
    var avatarURL: URL?
    var badge: Int = 0

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(AppTab.grouped, id: \.self) { tab in
                    TabItem(
                        tab: tab,
                        isSelected: selection == tab,
                        badge: tab == .home ? badge : 0
                    ) {
                        select(tab)
                    }
                }
            }
            .padding(5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))

            ProfileButton(
                isSelected: selection == .profile,
                avatarURL: avatarURL
            ) {
                select(.profile)
            }
        }
        .padding(.horizontal, 16)
        .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
    }

    private func select(_ tab: AppTab) {
        if selection == tab {
            onReselect(tab)
            return
        }
        // Snappy rather than bouncy: this fires on every navigation, and a
        // spring that overshoots gets tiring by the twentieth tap.
        withAnimation(.snappy(duration: 0.22)) { selection = tab }
    }
}

private struct TabItem: View {
    let tab: AppTab
    let isSelected: Bool
    let badge: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                // The label appears only on the selected item, so the bar stays
                // narrow enough to leave the avatar visibly separate.
                if isSelected {
                    Text(tab.title)
                        .font(.footnote.weight(.semibold))
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
            .padding(.horizontal, isSelected ? 14 : 16)
            .padding(.vertical, 10)
            .background {
                if isSelected {
                    Capsule().fill(Theme.softAccent)
                }
            }
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                        .offset(x: -2, y: 4)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Profile as a face rather than an icon. It is the one tab that is about a
/// person, so it looks like one.
private struct ProfileButton: View {
    let isSelected: Bool
    let avatarURL: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.regularMaterial)

                if let avatarURL {
                    AsyncImage(url: avatarURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: AppTab.profile.symbolName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                    }
                    .clipShape(Circle())
                    .padding(3)
                } else {
                    Image(systemName: AppTab.profile.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .overlay(
                Circle().strokeBorder(
                    isSelected ? Theme.accent : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? 2 : 1
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("You")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    struct Harness: View {
        @State private var tab: AppTab = .home
        var body: some View {
            VStack {
                Spacer()
                TabBar(selection: $tab, onReselect: { _ in }, avatarURL: nil, badge: 2)
                    .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
        }
    }
    return Harness()
}
