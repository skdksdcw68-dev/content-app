import SwiftUI

/// The one place brand colour is defined.
///
/// The rule the design sets: native iOS surfaces are the foundation, and the
/// accent marks AI actions and active states only. It never colours a whole
/// screen. Both tokens live here so re-branding is one file rather than a
/// search through every view.
enum Theme {
    /// #6C5CE7. Also the asset-catalog AccentColor, so unstyled system
    /// controls pick it up for free without being told.
    static let accent = Color.accentColor

    /// #EEECFF in light, a deep indigo in dark. The background behind a
    /// selected chip or an AI surface -- a tint, never a large fill.
    static let softAccent = Color("SoftAccent")

    /// Corner radius shared by every card, so surfaces read as one system.
    static let cornerRadius: CGFloat = 16

    /// Space the Create button needs at the bottom of a scrolling screen.
    /// Without it the last card sits under the button and cannot be tapped.
    static let createButtonClearance: CGFloat = 96
}

/// The standard surface: a grouped-background card.
///
/// `secondarySystemGroupedBackground` rather than a fixed colour, so Light
/// Mode, Dark Mode and increased contrast all work without a second palette.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    // Built once in the initialiser rather than being a stored closure --
    // @ViewBuilder only applies to something with a getter, not to a stored
    // property.
    var content: Content

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .labelStyle(.titleAndIcon)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        )
    }
}

/// One number and what it counts. The unit of the Insights grid and of the
/// performance strip on Home.
struct MetricTile: View {
    let label: String
    let value: String
    var caption: String?
    /// Metrics the platform has not reported are shown, not hidden -- an
    /// absent number is information, and hiding it looks like a bug.
    var isAvailable: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(isAvailable ? value : "\u{2014}")
                .font(.title2.weight(.semibold))
                .foregroundStyle(isAvailable ? Color.primary : Color.secondary)
                .contentTransition(.numericText())

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

/// A labelled proportion, drawn as a capsule track. Used for completion on
/// Home and for topic share on Insights.
struct ProportionBar: View {
    let fraction: Double
    var tint: Color = Theme.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.softAccent)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            Card("A card", systemImage: "sparkles") {
                Text("Native surface, accent only on the icon.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProportionBar(fraction: 0.6)
            }
            HStack(spacing: 12) {
                MetricTile(label: "Views", value: "18.4K", caption: "last 7 days")
                MetricTile(label: "Followers", value: "0", caption: "not reported", isAvailable: false)
            }
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
