import SwiftUI

/// The Claude app's settings look (Abel, 2 Nov 2026: "make the usage screen
/// look like the chat settings", both drawn like Claude's own Settings,
/// Billing and Effort pages from Mobbin): warm paper behind, soft grey groups
/// with hairline dividers, quiet captions above them.
extension Color {
    /// The page: warm off-white in light, Claude's charcoal in dark.
    static let claudePaper = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.149, green: 0.149, blue: 0.141, alpha: 1)
            : UIColor(red: 0.980, green: 0.976, blue: 0.969, alpha: 1)
    })

    /// What a group is made of.
    static let claudeGroup = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.188, green: 0.188, blue: 0.176, alpha: 1)
            : UIColor(red: 0.937, green: 0.929, blue: 0.914, alpha: 1)
    })
}

/// One soft rounded group. Rows go inside; `ClaudeDivider` goes between them.
struct ClaudeGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.claudeGroup, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The hairline between two rows of a group.
struct ClaudeDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

/// The small grey line above a group.
struct ClaudeCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
    }
}

/// A thin bar: a track, and the share laid over it.
struct ClaudeBar: View {
    /// 0 to 1.
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}
