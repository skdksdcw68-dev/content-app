import SwiftUI

/// The pieces of the Create settings sheet (`GeneratorSettingsSheet`), shared
/// with the sheet the chat opens before it makes something.
///
/// Abel, 4 Nov 2026: "make sure the model picker is exactly as the setting
/// one, which we used to see on the sheet, which looks perfect. Apply it for
/// the video, not just the photo ... also for the voices." Same cards, same
/// pills, same shape tiles, same row heights.
enum PickKit {
    /// A card on the sheet, Grok's colours (the mockup Abel approved).
    static var card: some View { PickCardFill() }

    /// "1k" reads as a typo; "1K" reads as a resolution. A bare "768" is a
    /// height in pixels, which people know as "768p".
    static func resolutionLabel(_ value: String) -> String {
        if value.hasSuffix("k") { return value.uppercased() }
        if !value.isEmpty, value.allSatisfy(\.isNumber) { return "\(value)p" }
        return value
    }
}

struct PickCardFill: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 21, style: .continuous)
            .fill(GrokLook.card(scheme))
    }
}

/// The sheet behind the cards.
struct PickSheetFill: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GrokLook.sheet(scheme).ignoresSafeArea()
    }
}

/// Generate, drawn as the paywall's Subscribe button: a solid capsule in the
/// page's colour reversed, and nothing else on it (Abel, 4 Nov 2026).
struct PickButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .foregroundStyle(.background)
            .background(isEnabled ? Color.primary : Color.primary.opacity(0.22), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
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
    /// The maker's own mark, so the row is recognised before it is read.
    var maker: ModelMaker? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let maker {
                ModelMakerMark(maker: maker, side: 32)
            }
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

/// The voices, laid out as the mockup has them: hear one, its name, what it
/// sounds like, a tick on the chosen one. Four show; the rest are a tap away.
struct PickVoiceList: View {
    let options: [String]
    /// Each voice's sample, by its full name.
    let samples: [String: String]
    @Binding var selection: String?

    @State private var showsAll = false

    private var shown: [String] {
        guard !showsAll, options.count > 4 else { return options }
        var first = Array(options.prefix(4))
        if let selection, !first.contains(selection) { first[3] = selection }
        return first
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(shown, id: \.self) { option in
                row(option)
                Divider().padding(.leading, 58)
            }
            if options.count > 4 {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showsAll.toggle() }
                } label: {
                    HStack {
                        Text(showsAll ? "Show fewer" : "All \(options.count) voices")
                        Spacer(minLength: 8)
                        Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                    }
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(PickKit.card)
        .sensoryFeedback(.selection, trigger: selection)
        .onDisappear { VoiceSamplePlayer.shared.stop() }
    }

    private func row(_ option: String) -> some View {
        let parts = option.split(separator: " - ", maxSplits: 1).map { String($0) }
        let name = parts.first ?? option
        let about = parts.count > 1 ? parts[1] : nil
        let sample = samples[option] ?? samples[name]
        let on = selection == option
        let playing = VoiceSamplePlayer.shared.playing == option
        return HStack(spacing: 12) {
            Button {
                guard let sample else { return }
                VoiceSamplePlayer.shared.toggle(VoiceSample(id: option, name: name, about: about ?? "", preview: sample))
            } label: {
                ZStack {
                    Circle().fill(sample == nil ? Self.tint(of: name) : Color.primary.opacity(0.10))
                    if sample == nil {
                        Text(String(name.prefix(1)))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(sample == nil)
            .accessibilityLabel(playing ? "Stop \(name)" : "Hear \(name)")

            Button {
                withAnimation(.snappy(duration: 0.18)) { selection = option }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.body.weight(on ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        if let about {
                            Text(about)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if on {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
    }

    /// A steady colour per voice, for one with no sample to play.
    private static func tint(of name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Color(hue: Double(sum % 360) / 360, saturation: 0.45, brightness: 0.72)
    }
}
