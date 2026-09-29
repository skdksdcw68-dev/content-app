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
///   ◷  how long                         -- video only; images have no length
///   ⤢  size (aspect ratio)              -- the frame it comes back in
///   ▦  pixels (resolution)              -- how sharp; moves the price
///   ♪  sound                            -- video models that make their own
///                                    ↑  send, alone on the right
///
/// A knob that does not apply is not greyed out, it is absent: the clock
/// disappears in image mode rather than sitting there dead, which is what
/// ElevenLabs does and why their image bar looks calmer than their video one.
///
/// 29 Sep 2026: absent is now decided by the MODEL, not by the mode. Kling has
/// no pixels setting, Wan and Kling make no sound, and a video that starts from
/// a picture takes the picture's own shape -- so on those the knob is not
/// there, where it used to be drawn and quietly ignored. The "how many" knob is
/// gone: it never produced more than one.
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
                // rather than carried -- and then replaced with the new
                // kind's recommendation, because a page with no model is a
                // page whose send button has stopped being a generate button.
                // With a picture in the composer, only a model that can work
                // from one is recommended.
                choices.model = nil
                Task {
                    let models = await session.models(
                        capability: choices.mode.capability,
                        withPicture: choices.pictured
                    )
                    if choices.model == nil {
                        choices.model = models.first(where: \.recommended) ?? models.first
                    }
                }
            }
            // A different model has different limits: keep what still applies
            // and move what does not, so "1080p" is never left selected on a
            // model that has no such thing.
            .onChange(of: choices.model) { _, _ in
                choices.fit()
            }

            // ✦ Which model.
            Button { showingModels = true } label: {
                Knob(symbol: "sparkles", chevron: true)
            }
            .buttonStyle(.plain)

            // ◷ How long. Video only -- an image has no length, and a dead
            // control is worse than no control. Only the lengths this model
            // makes: Veo offers 4, 6 and 8, Kling 5 and 10.
            if choices.isVideo, choices.lengths.count > 1 {
                Menu {
                    Picker("", selection: $choices.seconds) {
                        ForEach(choices.lengths, id: \.self) { Text("\($0)s").tag($0) }
                    }
                    .labelsHidden()
                } label: {
                    Knob(symbol: "clock", value: "\(choices.seconds)")
                }
            }

            // ⤢ The size it comes back in -- the model's own shapes. Absent
            // when a picture decides it.
            if choices.choosesShape, choices.aspects.count > 1 {
                Menu {
                    Picker("", selection: $choices.aspect) {
                        ForEach(choices.aspects, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                } label: {
                    Knob(symbol: "aspectratio", value: choices.aspect)
                }
            }

            // ▦ How sharp. Abel, 26 Sep 2026: "why are the users not allowed
            // to choose or pick the resolution huh??" They were -- in the
            // settings sheet, which is not where anybody looked. It belongs
            // out here with the others because it MOVES THE PRICE: Wan is
            // $0.05 a second at 480p and $0.15 at 1080p. Pictures have it too
            // now -- Nano Banana 2 goes from 0.5K to 4K.
            if choices.resolutions.count > 1 {
                Menu {
                    Picker("", selection: $choices.resolution) {
                        ForEach(choices.resolutions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                } label: {
                    Knob(symbol: "rectangle.on.rectangle", value: choices.resolution)
                }
            }

            // ♪ Sound, and the biggest lever on the bar: Veo 3.1 is $0.40
            // a second with it and $0.20 without. "which can reduce our
            // costs" -- by half, on the dearest model offered. Only where the
            // model makes sound at all.
            if choices.hasSound {
                Button {
                    withAnimation(.snappy(duration: 0.15)) { choices.audio.toggle() }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Knob(symbol: choices.audio ? "speaker.wave.2" : "speaker.slash")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choices.audio ? "Sound on" : "Sound off")
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
                withPicture: choices.pictured,
                selected: choices.model?.externalId
            ) { choices.model = $0 }
        }
    }
}

private extension GenerateBar {
    /// Everything that moves the price. The prompt is not in it, because no
    /// provider here charges by the word.
    ///
    /// Sound is in it: Veo is half the price without, and a number that did not
    /// move when the speaker was switched off was the number on the send button
    /// being wrong.
    var priceKey: String {
        [
            choices.model?.externalId ?? "",
            choices.mode.rawValue,
            String(choices.seconds),
            choices.resolution,
            choices.audio ? "sound" : "silent",
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
