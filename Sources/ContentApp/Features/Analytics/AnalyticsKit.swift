import SwiftUI

/// The pieces Analytics is built from, in the way TikTok Studio lays a page out
/// (Abel's reference, 17 Sep 2026) and in Remi's black and white: tabs with an
/// underline that stay put while the page scrolls, white cards with a title and
/// an ⓘ, soft chips for choosing, and bars for shares of a whole.

// MARK: - Tabs

struct UnderlineTabs<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    @Namespace private var underline

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 26) {
                    ForEach(items, id: \.self) { item in
                        tab(item)
                    }
                }
                .padding(.top, 8)
            }
            .contentMargins(.horizontal, Style.gutter, for: .scrollContent)

            Divider()
        }
        .background(Color.canvas)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func tab(_ item: Item) -> some View {
        let isOn = item == selection
        return Button {
            withAnimation(.snappy(duration: 0.25)) { selection = item }
        } label: {
            Text(title(item))
                .font(.body.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .padding(.bottom, 12)
                .overlay(alignment: .bottom) {
                    if isOn {
                        Capsule()
                            .fill(Color.primary)
                            .frame(height: 3)
                            .matchedGeometryEffect(id: "underline", in: underline)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Cards

struct AnalyticsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var info: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.title3.bold())
                    if let info {
                        InfoButton(text: info)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: 18)
    }
}

/// The ⓘ beside a title: what the number means, in a small popover.
struct InfoButton: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About this")
        .popover(isPresented: $showing) {
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(14)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// A section TikTok only shares with Business accounts. Said plainly, instead
/// of a card full of dashes that looks like it is loading forever.
struct BusinessOnlyCard: View {
    let title: String
    let detail: String
    var needsFollowers = false

    var body: some View {
        AnalyticsCard(title: title) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.track, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(needsFollowers
                         ? "Comes with a TikTok Business connection, once the account has 100 followers."
                         : "Comes with a TikTok Business connection. Autocast shows it as soon as that is set up.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Choosing

/// Studio's filter chips, in Remi's colours: the chosen one on a faint ink
/// wash with dark words, the rest on the quiet grey.
struct SoftChips<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    chip(item)
                }
            }
        }
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func chip(_ item: Item) -> some View {
        let isOn = item == selection
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selection = item }
        } label: {
            Text(title(item))
                .font(.subheadline.weight(isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isOn ? Color.accentColor.opacity(0.12) : Color.track)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shares of a whole

struct PercentBarRow: View {
    let label: String
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.track)
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - A number in a box

/// Studio's key-metric tile: the name, the number, and one line under it.
/// Tappable when it drives a chart; chosen, it takes an ink border.
struct KeyTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var captionColor: Color = .secondary
    var isSelected = false
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { tile }
                .buttonStyle(SoftPressStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            tile
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(captionColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.05) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color(uiColor: .separator),
                              lineWidth: isSelected ? 1.5 : 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
