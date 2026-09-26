import SwiftUI

/// The row of controls under the composer, in ElevenLabs' order.
///
/// Abel, 25 Sep 2026: "since its not corrected well, means the order so i want
/// it to match the exact eleven labs thing, that makes more sense and looks so
/// good."
///
/// The order is the whole point and it is not arbitrary. Left to right it goes
/// from the widest decision to the narrowest:
///
///   ⚙︎  everything, in a sheet          -- the escape hatch, furthest left
///   │   a hairline, so the sheet reads as separate from the six
///   ▶︎  image or video                  -- decides what the rest even mean
///   ✦  which model                      -- decides what it can do
///   ⧉  how many                         -- decides what it costs
///   ◷  how long                         -- video only; images have no length
///   ⤢  aspect ratio                     -- the frame it comes back in
///                                    ↑  send, alone on the right
///
/// A knob that does not apply is not greyed out, it is absent: the clock
/// disappears in image mode rather than sitting there dead, which is what
/// ElevenLabs does and why their image bar looks calmer than their video one.
struct GenerateBar: View {
    @Binding var choices: GenerateChoices
    /// What is being typed, so a price is this job's price.
    let request: String

    @Environment(AppSession.self) private var session

    @State private var showingSettings = false
    @State private var showingModels = false
    @State private var showingMode = false
    /// What this exact request costs, asked of the provider whenever the
    /// choices change. Nil while unknown, and shown as nothing rather than
    /// as zero -- free and unpriced are different facts.
    @State private var credits: Int?
    @State private var pricing: Task<Void, Never>?

    /// The lengths worth offering. Abel, 25 Sep: "just let the user hit and
    /// pick what second he wants" -- the stepper in the sheet does that; this
    /// is the quick tap.
    private static let lengths = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180]
    private static let aspects = ["9:16", "1:1", "4:5", "16:9"]

    var body: some View {
        HStack(spacing: 0) {
            // ⚙︎ Everything, in a sheet.
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 16)
                .padding(.trailing, 4)

            // ▶︎ Image or video. A menu rather than a toggle, because
            // ElevenLabs shows the two by name and a toggle would not.
            Menu {
                Picker("", selection: $choices.mode) {
                    ForEach(GenerateChoices.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
            } label: {
                Knob(symbol: choices.mode.symbol, chevron: true)
            }
            .onChange(of: choices.mode) { _, _ in
                // A model chosen for video cannot make an image. Cleared
                // rather than carried, so the bar never names something that
                // would be refused on send.
                choices.model = nil
            }

            // ✦ Which model.
            Button { showingModels = true } label: {
                Knob(symbol: "sparkles", chevron: true)
            }
            .buttonStyle(.plain)

            // ⧉ How many.
            Menu {
                Picker("", selection: Binding(get: { choices.count }, set: { choices.count = $0 })) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
            } label: {
                Knob(symbol: "square.stack.3d.up", value: "\(choices.count)")
            }

            // ◷ How long. Video only -- an image has no length, and a dead
            // control is worse than no control.
            if choices.isVideo {
                Menu {
                    Picker("", selection: $choices.seconds) {
                        ForEach(Self.lengths, id: \.self) { Text("\($0)s").tag($0) }
                    }
                    .labelsHidden()
                } label: {
                    Knob(symbol: "clock", value: "\(choices.seconds)")
                }
            }

            // ⤢ The frame it comes back in.
            Menu {
                Picker("", selection: $choices.aspect) {
                    ForEach(Self.aspects, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            } label: {
                Knob(symbol: "aspectratio", value: choices.aspect)
            }

            Spacer(minLength: 0)

            // What it will cost, beside the send button. Abel, 26 Sep 2026:
            // "make sure the send button has the credits thing also."
            if let credits {
                HStack(spacing: 3) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 8))
                    Text("\(credits)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                }
                .foregroundStyle(.secondary)
                .padding(.trailing, 2)
                .transition(.opacity)
                .accessibilityLabel("\(credits) credits")
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 4)
        .animation(.easeOut(duration: 0.2), value: credits)
        // Re-priced when anything that changes the bill changes: the model,
        // the length, how many, and the resolution. Not on every keystroke --
        // the prompt does not move the price on any provider here.
        .task(id: priceKey) { await reprice() }
        .onDisappear { pricing?.cancel() }
        .sheet(isPresented: $showingSettings) {
            GenerateSettingsSheet(choices: $choices, request: request)
        }
        .sheet(isPresented: $showingModels) {
            ModelBrowser(
                capability: choices.mode.capability,
                request: request,
                settings: choices.settings,
                withPicture: false,
                selected: choices.model?.externalId
            ) { choices.model = $0 }
        }
    }
}

private extension GenerateBar {
    /// Everything that moves the price. The prompt is not in it, because no
    /// provider here charges by the word.
    var priceKey: String {
        [
            choices.model?.externalId ?? "",
            choices.mode.rawValue,
            String(choices.count),
            String(choices.seconds),
            choices.resolution,
        ].joined(separator: "|")
    }

    func reprice() async {
        pricing?.cancel()
        guard let model = choices.model else {
            // No model chosen means the router picks, and what it picks
            // decides the price -- so there is no honest number to show yet.
            credits = nil
            return
        }
        let cost = await session.quote(
            capability: choices.mode.capability,
            model: model.externalId,
            prompt: request,
            settings: choices.settings
        )
        credits = GenerateChoices.credits(from: cost)
    }
}

/// One control on the bar: a glyph, then either a value or a chevron.
///
/// Deliberately small and quiet. These sit under a text field somebody is
/// typing in, and six loud buttons would pull the eye off the words.
private struct Knob: View {
    let symbol: String
    var value: String? = nil
    var chevron: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
            if let value {
                Text(value)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .contentTransition(.numericText())
            }
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 30)
        .contentShape(Rectangle())
    }
}
