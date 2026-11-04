import SwiftUI

/// The pieces of the Create settings sheet (`GeneratorSettingsSheet`), shared
/// with the sheet the chat opens before it makes something.
///
/// Abel, 4 Nov 2026: "make sure the model picker is exactly as the setting
/// one, which we used to see on the sheet, which looks perfect. Apply it for
/// the video, not just the photo ... also for the voices." Same cards, same
/// pills, same shape tiles, same row heights.
enum PickKit {
    static var card: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }

    /// "1k" reads as a typo; "1K" reads as a resolution. A bare "768" is a
    /// height in pixels, which people know as "768p".
    static func resolutionLabel(_ value: String) -> String {
        if value.hasSuffix("k") { return value.uppercased() }
        if !value.isEmpty, value.allSatisfy(\.isNumber) { return "\(value)p" }
        return value
    }
}

/// A grey label over a group.
struct PickHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 8)
    }
}

/// A label on the left and its control on the right, on a card.
struct PickRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            content
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(PickKit.card)
    }
}

/// Grok's segmented pills: the chosen one filled, the rest quiet.
struct PickSegments<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T?
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = selection == option
                Button {
                    withAnimation(.snappy(duration: 0.18)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color(.systemBackground) : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background {
                            if on { Capsule().fill(Color.primary) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A choice with a few short answers sits on one row; a longer one gets its
/// title above and pills that scroll, so nothing is cut off on a phone.
struct PickChoice<T: Hashable>: View {
    let title: String
    let options: [T]
    @Binding var selection: T?
    let label: (T) -> String

    private var fitsOnOneRow: Bool {
        options.count <= 3 && options.map { label($0).count }.reduce(0, +) <= 16
    }

    var body: some View {
        if fitsOnOneRow {
            PickRow(title) {
                PickSegments(options: options, selection: $selection, label: label)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.body)
                ScrollView(.horizontal, showsIndicators: false) {
                    PickSegments(options: options, selection: $selection, label: label)
                }
                .scrollClipDisabled()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PickKit.card)
        }
    }
}

/// A long list of answers -- thirteen voices -- as rows with a tick.
struct PickList: View {
    let options: [String]
    @Binding var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                Button {
                    withAnimation(.snappy(duration: 0.18)) { selection = option }
                } label: {
                    HStack(spacing: 12) {
                        Text(option)
                            .font(.body.weight(selection == option ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if selection == option {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
                if index < options.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(PickKit.card)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// The shape tiles: each drawn in its own proportions, the chosen one filled.
struct PickShapes: View {
    let shapes: [String]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shape")
                .font(.body)
            if shapes.count <= 5 {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(shapes, id: \.self) { tile($0).frame(maxWidth: .infinity) }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(shapes, id: \.self) { tile($0).frame(width: 60) }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .padding(14)
        .background(PickKit.card)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func tile(_ shape: String) -> some View {
        let on = selection == shape
        let size = Self.size(of: shape)
        return Button {
            withAnimation(.snappy(duration: 0.18)) { selection = shape }
        } label: {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? Color.primary : Color.primary.opacity(0.14))
                    .frame(width: size.width, height: size.height)
                Text(shape)
                    .font(.caption.weight(on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shape \(shape)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The tile for a shape, fitted in a 38-point box.
    static func size(of shape: String) -> CGSize {
        let parts = shape.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return CGSize(width: 30, height: 30) }
        let ratio = parts[0] / parts[1]
        let box = 38.0
        return ratio >= 1 ? CGSize(width: box, height: box / ratio) : CGSize(width: box * ratio, height: box)
    }
}

/// The model, as a row that opens the list.
struct PickModelRow: View {
    let name: String
    let detail: String?
    let share: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail?.isEmpty == false ? detail! : "Model")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let share {
                Text(share)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
        .background(PickKit.card)
        .contentShape(Rectangle())
    }
}

/// What to make, in their words, on a card.
struct PickTextCard: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...6)
            .font(.body)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PickKit.card)
    }
}

/// A quiet line under a group: why a row is missing, how long it takes.
struct PickNote: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .fixedSize(horizontal: false, vertical: true)
    }
}
