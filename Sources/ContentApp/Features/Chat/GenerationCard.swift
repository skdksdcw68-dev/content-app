import SwiftUI

/// Choose, see the price, confirm -- then it is made.
///
/// Replaces a list of model names that started a paid job on the first tap.
/// Abel asked for the shape Higgsfield's own screen has: pick the model, pick
/// the quality, see exactly what it costs, press Generate. So:
///
///   - the models that can do it, cheapest first, each with its real price
///     from the provider and the provider's own one-line description; any the
///     balance cannot cover are shown but cannot be picked
///   - the quality and length the SELECTED model actually offers, read from
///     its catalogue entry, starting on its own default or on what was asked
///   - one button carrying the price of exactly that combination, asked of the
///     provider again whenever something changes
///
/// Nothing is spent until that button is pressed.
struct GenerationCard: View {
    let offer: ModelOffer
    let request: String?
    /// Set once Generate was pressed (or on a reopened conversation, once it
    /// was answered). The card then settles into one line saying what was made.
    let settled: String?
    let onGenerate: (ModelChoice, GenerationSettings, ModelCost?) -> Void

    @Environment(AppSession.self) private var session
    @State private var selectedID: String?
    /// A model chosen from the full list, which the offer's eight rows do not
    /// contain. It joins them at the top rather than replacing the card.
    @State private var picked: ModelChoice?
    @State private var browsing = false
    @State private var resolution: String?
    @State private var duration: Double?
    @State private var quality: String?
    /// What the chosen model asks for by name: a voice, an engine. Keyed by
    /// the provider's own parameter name, so nothing about them is written
    /// down here.
    @State private var extras: [String: String] = [:]
    /// The size, the sound and the line to be spoken -- what the card used to
    /// leave out entirely. Netro, 29 Sep 2026, with a screenshot of it: "it
    /// doesn't include every single thing, doesn't include all the required
    /// things like voiceover, the pixels, the size."
    @State private var aspect: String?
    @State private var sound = true
    @State private var voiceover = ""
    /// What should happen, in the person's words. Starts on the request the
    /// agent understood, and is theirs to change: the card is the last place
    /// to say it before anything is spent.
    @State private var prompt = ""
    @State private var price: ModelCost?
    @State private var pricing = false
    @State private var pricingTask: Task<Void, Never>?

    /// The rows on the card: what was offered, plus anything chosen from the
    /// full list.
    private var options: [ModelChoice] {
        guard let picked, !offer.options.contains(where: { $0.externalId == picked.externalId }) else {
            return offer.options
        }
        return [picked] + offer.options
    }

    private var selected: ModelChoice? {
        options.first { $0.externalId == selectedID }
    }

    /// A picture has no length; a video and a piece of music both do.
    private var hasLength: Bool { offer.capability != "image_generation" }

    private var isVideo: Bool { offer.capability == "video_generation" }
    private var withPicture: Bool { offer.withPicture ?? false }

    /// The shapes the chosen model makes.
    private var shapes: [String] { selected?.constraints.aspectRatios ?? [] }

    /// The size is the person's to choose, unless a picture decides it: a video
    /// that starts from one takes its shape.
    private var choosesShape: Bool { shapes.count > 1 && !(isVideo && withPicture) }

    /// Sound is a row only where the model says it makes sound. A switch on a
    /// model that cannot is a switch that does nothing.
    private var hasSound: Bool { isVideo && selected?.constraints.audio == true }

    /// The model will read a line out, if given one.
    private var canSpeak: Bool { hasSound && sound }

    var body: some View {
        if let settled {
            Label(settled, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accent)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                models

                // The size. For a video that starts from a picture there is
                // nothing to choose, and the card says so rather than dropping
                // the row without a word.
                if choosesShape {
                    ChoiceChips(title: "Size", options: shapes, label: { $0 }, selection: $aspect)
                } else if isVideo, withPicture {
                    Label("The video takes the shape of your picture", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // The pixels. "Resolution" to a provider; pixels to everyone else.
                if let options = selected?.constraints.resolutions, options.count > 1 {
                    ChoiceChips(title: "Pixels", options: options, label: resolutionLabel, selection: $resolution)
                }

                if let options = selected?.constraints.qualities, options.count > 1 {
                    ChoiceChips(title: "Quality", options: options, label: { $0.capitalized }, selection: $quality)
                }

                // Whatever else this model will not run without -- Inworld's
                // thirteen voices, an engine to use. Read from its own entry.
                ForEach(selected?.constraints.choices ?? []) { ask in
                    ChoiceChips(
                        title: ask.label,
                        options: ask.options,
                        label: { $0 },
                        selection: Binding(
                            get: { extras[ask.name] },
                            set: { extras[ask.name] = $0 }
                        )
                    )
                }

                if hasLength, let options = selected?.constraints.durations, options.count > 1 {
                    ChoiceChips(
                        title: "Length",
                        options: options,
                        label: { "\(Int($0.rounded()))s" },
                        selection: $duration
                    )
                }

                if hasSound {
                    soundRow
                } else if isVideo, selected?.constraints.audio == false {
                    // Said, not left out: "where is the voiceover?" is the
                    // question a card with no sound row invites.
                    Label("This model makes silent video", systemImage: "speaker.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if canSpeak {
                    voiceoverField
                }

                // Last before Generate, on purpose. The conversation scrolls to
                // its end when the keyboard rises, and a field at the top of a
                // tall card would be scrolled out of sight under the words being
                // typed into it.
                promptField

                generateButton
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.surface)
            }
            .task { start() }
            .onChange(of: selectedID) { _, _ in
                // A new model has its own choices; keep what still applies.
                adoptDefaults(keeping: true)
                reprice()
            }
            .onChange(of: resolution) { _, _ in reprice() }
            .onChange(of: duration) { _, _ in reprice() }
            .onChange(of: quality) { _, _ in reprice() }
            .onChange(of: extras) { _, _ in reprice() }
            // Sound moves the price -- Veo is half as much without it.
            .onChange(of: sound) { _, _ in reprice() }
            .sheet(isPresented: $browsing) {
                ModelBrowser(
                    capability: offer.capability,
                    request: request ?? "",
                    settings: current,
                    withPicture: offer.withPicture ?? false,
                    selected: selectedID
                ) { choice in
                    picked = choice
                    selectedID = choice.externalId
                }
            }
        }
    }

    // MARK: - Pieces

    /// What should happen, editable. The card used to show only model names,
    /// so the one thing the person had actually typed was nowhere on it.
    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isVideo ? "What should happen?" : offer.capability == "image_generation" ? "What should it show?" : "Prompt")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Describe it", text: $prompt, axis: .vertical)
                .lineLimit(1...5)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
        }
    }

    private var soundRow: some View {
        Toggle(isOn: $sound) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sound")
                    .font(.subheadline.weight(.semibold))
                Text(sound ? "It makes its own sound" : "Silent, and it costs less")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Theme.accent)
    }

    /// The line the voice reads. Optional: left empty, the model chooses what
    /// to say, or nothing.
    private var voiceoverField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Voiceover")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("What should the voice say? (optional)", text: $voiceover, axis: .vertical)
                .lineLimit(1...4)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
        }
    }

    private var models: some View {
        VStack(spacing: 6) {
            ForEach(options) { option in
                let usable = option.affordable != false
                Button {
                    if usable { selectedID = option.externalId }
                } label: {
                    ModelOptionRow(
                        option: option,
                        isSelected: option.externalId == selectedID,
                        price: option.externalId == selectedID ? (price ?? option.cost) : option.cost
                    )
                }
                .buttonStyle(PressButtonStyle())
                .disabled(!usable)
            }

            // Eight rows is a shortlist. The rest are one tap away, grouped by
            // family, searchable and priced as they are looked at.
            Button { browsing = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                    Text(offer.total.map { "All \($0) models" } ?? "All models")
                        .fontWeight(.semibold)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle())
        }
    }

    private var generateButton: some View {
        Button {
            guard let selected else { return }
            onGenerate(selected, current, price ?? selected.cost)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Generate")
                    .fontWeight(.semibold)
                Spacer(minLength: 8)
                if pricing {
                    ProgressView().controlSize(.small).tint(Theme.onAccent)
                } else if let shown = price ?? selected?.cost, shown.amount != nil {
                    Text(shown.label)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(RemiFilledButtonStyle())
        .tint(Theme.accent)
        .controlSize(.large)
        .disabled(selected == nil || selected?.affordable == false)
    }

    // MARK: - Behaviour

    private func start() {
        guard selectedID == nil else { return }
        if prompt.isEmpty { prompt = request ?? "" }
        let usable = offer.options.filter { $0.affordable != false }
        selectedID = [offer.preselect, offer.auto?.externalId]
            .compactMap { $0 }
            .first { id in usable.contains { $0.externalId == id } }
            ?? usable.first?.externalId
            ?? offer.options.first?.externalId
        adoptDefaults(keeping: false)
        price = selected?.cost
        // The first price was asked for the settings Autocast guessed; if the
        // card starts on different ones, ask again so the button is true.
        if resolution != nil || duration != nil { reprice() }
    }

    /// The selected model's own defaults, or what was asked for in words when
    /// the model offers it. "2k" typed earlier starts the card on 2K.
    private func adoptDefaults(keeping: Bool) {
        guard let selected else { return }
        let resolutions = selected.constraints.resolutions ?? []
        let wanted = keeping ? resolution : offer.settings?.resolution
        resolution = match(wanted, in: resolutions)
            ?? match(selected.constraints.defaults?.resolution, in: resolutions)
            ?? resolutions.first

        // The size: kept if the new model makes it, else what was asked for in
        // words, else vertical -- this app makes videos for a phone.
        let shapes = selected.constraints.aspectRatios ?? []
        aspect = match(keeping ? aspect : offer.settings?.aspectRatio, in: shapes)
            ?? match("9:16", in: shapes)
            ?? shapes.first

        let durations = selected.constraints.durations ?? []
        let asked = keeping ? duration : offer.settings?.duration
        if let asked, let nearest = durations.min(by: { abs($0 - asked) < abs($1 - asked) }) {
            duration = nearest
        } else {
            duration = selected.constraints.defaults?.duration ?? durations.first
        }
        if !hasLength { duration = nil }

        // Each of the model's own questions starts on its default, or on the
        // first answer it accepts -- never empty, or Generate would send a job
        // the model refuses.
        var answers: [String: String] = [:]
        for ask in selected.constraints.choices ?? [] {
            let kept = keeping ? extras[ask.name] : nil
            answers[ask.name] = ask.options.first { $0 == kept }
                ?? ask.options.first { $0 == ask.preset }
                ?? ask.options.first
        }
        extras = answers

        let qualities = selected.constraints.qualities ?? []
        quality = match(keeping ? quality : nil, in: qualities)
            ?? match(selected.constraints.defaults?.quality, in: qualities)
            ?? qualities.first
    }

    /// Everything set on the card, as it would be sent.
    ///
    /// 🔴 The size, the sound and the person's own words all stayed on the
    /// card. Only the pixels, the length and a quality ever left it, so "9:16"
    /// could not have been chosen and a silent video could not have been asked
    /// for. The adapter takes each of these in that model's own spelling and
    /// drops what it does not have.
    private var current: GenerationSettings {
        var all = extras
        if choosesShape, let aspect { all["aspect_ratio"] = aspect }
        if hasSound { all["generate_audio"] = sound ? "true" : "false" }
        var settings = GenerationSettings(resolution: resolution, duration: duration, quality: quality, extras: all)
        settings.prompt = finalPrompt
        return settings
    }

    /// The words as they will be sent: what is in the field, and the line to
    /// speak on the end. Nil when neither changed anything, so an unedited
    /// card still answers the offer it came from.
    private var finalPrompt: String? {
        let written = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let asked = (request ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var text = written.isEmpty ? asked : written
        if canSpeak { text = GenerateChoices.adding(voiceover: voiceover, to: text) }
        return text == asked || text.isEmpty ? nil : text
    }

    private func match(_ wanted: String?, in options: [String]) -> String? {
        guard let wanted else { return nil }
        return options.first { $0.lowercased() == wanted.lowercased() }
    }

    /// Asks the provider for exactly this combination, a moment after the last
    /// change -- tapping through three qualities should cost one request.
    private func reprice() {
        guard let selected else { return }
        pricingTask?.cancel()
        pricing = true
        let settings = current
        pricingTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let quoted = await session.quote(
                capability: offer.capability,
                model: selected.externalId,
                prompt: request ?? "",
                settings: settings
            )
            guard !Task.isCancelled else { return }
            if let quoted, quoted.amount != nil { price = quoted }
            pricing = false
        }
    }

    private func resolutionLabel(_ value: String) -> String {
        // "1k" reads as a typo; "1K" reads as a resolution. And a bare "768"
        // is a height in pixels, which people know as "768p".
        if value.hasSuffix("k") { return value.uppercased() }
        if !value.isEmpty, value.allSatisfy(\.isNumber) { return "\(value)p" }
        return value
    }
}

/// One model: a radio mark, its name and what it is for, and its price.
private struct ModelOptionRow: View {
    let option: ModelChoice
    let isSelected: Bool
    let price: ModelCost

    private var usable: Bool { option.affordable != false }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary.opacity(0.5))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    ForEach(option.badges ?? [], id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(badge == "Cheapest" ? Color.green : Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((badge == "Cheapest" ? Color.green : Theme.accent).opacity(0.12)))
                    }
                }
                if let note = option.constraints.notes?.first {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(usable ? Color.secondary : Color.orange)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 8)

            Text(price.amount == nil ? "—" : price.label)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(usable ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.10) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.35) : Color(uiColor: .separator).opacity(0.5), lineWidth: 1)
        }
        .opacity(usable ? 1 : 0.55)
        .contentShape(Rectangle())
    }
}

/// A row of options, one selected. Used for quality and length.
private struct ChoiceChips<Value: Hashable>: View {
    let title: String
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // Scrolls, because a model can offer thirteen voices and a phone is
            // 390 points wide. Two or three read exactly as they did.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        let isOn = option == selection
                        Button { selection = option } label: {
                            Text(label(option))
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .foregroundStyle(isOn ? Theme.onAccent : Color.primary)
                                .background(Capsule().fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.07))))
                        }
                        .buttonStyle(PressButtonStyle())
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollClipDisabled()
        }
    }
}
