import SwiftUI

/// Choose, see the price, confirm -- then it is made.
///
/// Pick the model, pick what it offers, see exactly what it costs, press
/// Generate. Nothing is spent until that button is pressed.
///
/// Abel, 4 Nov 2026: the choosing happens on a sheet laid out exactly like the
/// Create settings sheet, holding only what this kind of thing needs -- a
/// picture gets picture rows, never video ones. A new offer opens the sheet by
/// itself; the chat keeps a small card that opens it again.
struct GenerationCard: View {
    let offer: ModelOffer
    let request: String?
    /// Set once Generate was pressed (or on a reopened conversation, once it
    /// was answered). The card then settles into one line saying what was made.
    let settled: String?
    /// Drawn straight into a sheet that is already open (the video sheet).
    var inline = false
    /// A new offer opens its sheet at once, once per `key`.
    var opensAtOnce = false
    var key = ""
    let onGenerate: (ModelChoice, GenerationSettings, ModelCost?) -> Void

    @Environment(AppSession.self) private var session
    @State private var selectedID: String?
    /// A model chosen from the full list, which the offer's rows do not
    /// contain. It joins them at the top.
    @State private var picked: ModelChoice?
    @State private var showing = false
    @State private var listing = false
    @State private var browsing = false
    @State private var resolution: String?
    @State private var duration: Double?
    @State private var quality: String?
    /// What the chosen model asks for by name: a voice, an engine. Keyed by
    /// the provider's own parameter name.
    @State private var extras: [String: String] = [:]
    @State private var aspect: String?
    @State private var sound = true
    @State private var voiceover = ""
    /// What should happen, in the person's words. Starts on the request.
    @State private var prompt = ""
    /// How many separate pictures. Each is its own job, priced as one.
    @State private var count = 1
    @State private var price: ModelCost?
    @State private var pricing = false
    @State private var pricingTask: Task<Void, Never>?

    /// Offers whose sheet already opened by itself, so scrolling back past one
    /// does not open it again.
    @MainActor private static var opened: Set<String> = []

    private var options: [ModelChoice] {
        guard let picked, !offer.options.contains(where: { $0.externalId == picked.externalId }) else {
            return offer.options
        }
        return [picked] + offer.options
    }

    private var selected: ModelChoice? {
        options.first { $0.externalId == selectedID }
    }

    private var isPicture: Bool { offer.capability == "image_generation" }
    private var isVideo: Bool { offer.capability == "video_generation" }
    private var isVoice: Bool { offer.capability == "voice_generation" }
    /// A picture has no length; a video and a piece of music both do.
    private var hasLength: Bool { !isPicture }
    private var withPicture: Bool { offer.withPicture ?? false }

    /// How many pictures were asked for. Abel, 1 Nov 2026: asked for four, he
    /// got one picture split into four -- so each is its own job.
    private var offeredCount: Int {
        guard isPicture else { return 1 }
        return min(10, max(1, offer.settings?.count ?? 1))
    }
    private var counts: [Int] { Array(Set([1, 2, 4, offeredCount])).sorted() }
    private var countBinding: Binding<Int?> {
        Binding(get: { count }, set: { count = $0 ?? 1 })
    }

    /// The shapes the chosen model makes.
    private var shapes: [String] { selected?.constraints.aspectRatios ?? [] }
    /// A video that starts from a picture takes the picture's shape.
    private var choosesShape: Bool { shapes.count > 1 && !(isVideo && withPicture) }
    private var resolutionOptions: [String] { selected?.constraints.resolutions ?? [] }
    private var qualityOptions: [String] { selected?.constraints.qualities ?? [] }
    private var lengthOptions: [Double] { hasLength ? (selected?.constraints.durations ?? []) : [] }
    private var asks: [ModelConstraints.Ask] { selected?.constraints.choices ?? [] }

    /// Sound is a row only where the model makes sound AND can switch it.
    private var hasSound: Bool {
        guard isVideo, let constraints = selected?.constraints, constraints.audio == true else { return false }
        return constraints.audioSwitch != false
    }
    /// Makes sound that cannot be turned off (MiniMax H3).
    private var soundIsAlwaysOn: Bool {
        guard isVideo, let constraints = selected?.constraints else { return false }
        return constraints.audio == true && constraints.audioSwitch == false
    }
    /// The model will read a line out, if given one.
    private var canSpeak: Bool { (hasSound && sound) || soundIsAlwaysOn }

    private var hasSettings: Bool {
        isPicture || isVideo || resolutionOptions.count > 1 || qualityOptions.count > 1
            || lengthOptions.count > 1 || !asks.isEmpty
    }

    private var kindTitle: String {
        isPicture ? "Picture" : isVideo ? "Video" : isVoice ? "Voice" : "Sound"
    }
    private var kindSymbol: String {
        isPicture ? "photo" : isVideo ? "film" : isVoice ? "waveform" : "music.note"
    }
    private var groupTitle: String { isPicture ? "Pictures" : kindTitle }
    private var promptTitle: String {
        isVideo ? "What should happen?" : isPicture ? "What should it show?" : isVoice ? "What should it say?" : "What should it sound like?"
    }
    /// How long it really takes, measured (Nov 2026).
    private var timing: String {
        isVideo ? "Takes 2 to 5 minutes. I'll ping you when it's ready."
            : isPicture ? "Usually ready in under a minute."
            : "Ready in a few seconds."
    }

    var body: some View {
        if let settled {
            Label(settled, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accent)
        } else if inline {
            watched(form)
                .navigationDestination(isPresented: $listing) { modelList }
        } else {
            watched(summary)
                .sheet(isPresented: $showing) { pickSheet }
        }
    }

    /// Everything that keeps the price true, on whichever view stays on screen.
    private func watched<Content: View>(_ content: Content) -> some View {
        content
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
    }

    // MARK: - In the chat

    private var summary: some View {
        Button { showing = true } label: {
            HStack(spacing: 12) {
                Image(systemName: kindSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.map { "\(kindTitle) · \($0.label)" } ?? kindTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Open")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .accessibilityHint("Opens the \(kindTitle.lowercased()) settings")
    }

    private var summaryLine: String {
        var parts: [String] = []
        if isPicture, count > 1 { parts.append("\(count) pictures") }
        if choosesShape, let aspect { parts.append(aspect) }
        if let resolution { parts.append(PickKit.resolutionLabel(resolution)) }
        if let quality { parts.append(quality.capitalized) }
        if hasLength, let duration { parts.append("\(Int(duration.rounded()))s") }
        if let share = shareText(for: selected, times: count) { parts.append("\(share) of your month") }
        return parts.isEmpty ? "Pick a model, then tap Generate" : parts.joined(separator: " · ")
    }

    // MARK: - The sheet

    private var pickSheet: some View {
        NavigationStack {
            ScrollView {
                form
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                generateArea
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .background(Color(.systemGroupedBackground))
            }
            .navigationTitle(kindTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showing = false } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(isPresented: $listing) { modelList }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(34)
        .presentationDragIndicator(.visible)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            PickHeading("Model")
            Button { listing = true } label: {
                PickModelRow(
                    name: selected?.label ?? "Pick a model",
                    detail: selected?.about ?? selected?.reason,
                    share: shareText(for: selected)
                )
            }
            .buttonStyle(.plain)

            if hasSettings {
                PickHeading(groupTitle)
                settingsRows
            }

            PickHeading(promptTitle)
            PickTextCard(placeholder: "Describe it", text: $prompt)

            if canSpeak {
                PickHeading("Voiceover")
                PickTextCard(placeholder: "What should the voice say? (optional)", text: $voiceover)
            }

            if inline {
                generateArea.padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private var settingsRows: some View {
        if isPicture {
            PickChoice(title: "How many", options: counts, selection: countBinding, label: { "\($0)" })
        }
        if choosesShape {
            PickShapes(shapes: shapes, selection: $aspect)
        } else if isVideo, withPicture {
            PickNote(text: "The video takes the shape of your picture", symbol: "photo")
        }
        if resolutionOptions.count > 1 {
            PickChoice(
                title: resolutionOptions.allSatisfy { !$0.contains(where: \.isNumber) } ? "Quality" : "Resolution",
                options: resolutionOptions,
                selection: $resolution,
                label: PickKit.resolutionLabel
            )
        }
        if qualityOptions.count > 1 {
            PickChoice(title: "Quality", options: qualityOptions, selection: $quality, label: { $0.capitalized })
        }
        // Whatever else this model will not run without -- its voices, an
        // engine. Read from its own entry.
        ForEach(asks) { ask in
            askRow(ask)
        }
        if lengthOptions.count > 1 {
            PickChoice(title: "Length", options: lengthOptions, selection: $duration, label: { "\(Int($0.rounded()))s" })
        }
        if hasSound {
            PickRow("Sound") {
                Toggle("Sound", isOn: $sound)
                    .labelsHidden()
                    .tint(.green)
            }
        } else if soundIsAlwaysOn {
            PickNote(text: "Sound is included", symbol: "speaker.wave.2")
        } else if isVideo, selected?.constraints.audio == false {
            PickNote(text: "This model makes silent video", symbol: "speaker.slash")
        }
    }

    @ViewBuilder
    private func askRow(_ ask: ModelConstraints.Ask) -> some View {
        let binding = Binding<String?>(get: { extras[ask.name] }, set: { extras[ask.name] = $0 })
        if ask.options.count > 6 {
            PickHeading(ask.label)
            PickList(options: ask.options, selection: binding)
        } else {
            PickChoice(title: ask.label, options: ask.options, selection: binding, label: { $0 })
        }
    }

    private var generateArea: some View {
        VStack(spacing: 8) {
            PickNote(text: timing, symbol: "clock")
            generateTap
        }
        .frame(maxWidth: .infinity)
    }

    private var generateTap: some View {
        Button {
            guard let selected else { return }
            // The count travels with the job only, never with a price asked
            // of the provider: some would multiply it in, some would not.
            var settings = current
            if count > 1 { settings.extras["count"] = "\(count)" }
            showing = false
            onGenerate(selected, settings, price ?? selected.cost)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text(count > 1 ? "Generate \(count)" : "Generate")
                    .fontWeight(.semibold)
                Spacer(minLength: 8)
                if pricing {
                    ProgressView().controlSize(.small).tint(Theme.onAccent)
                } else if let share = shareText(for: selected, times: count) {
                    Text("\(share) of your month")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .accessibilityLabel("Uses \(share) of your month")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(RemiFilledButtonStyle())
        .tint(Theme.accent)
        .controlSize(.large)
        .disabled(selected == nil || selected?.affordable == false)
    }

    private var modelList: some View {
        PickModelList(
            title: "\(kindTitle) model",
            options: options,
            auto: offer.auto,
            total: offer.total,
            capability: offer.capability,
            selectedID: $selectedID,
            price: price,
            onBrowse: { browsing = true }
        )
        .sheet(isPresented: $browsing) {
            ModelBrowser(
                capability: offer.capability,
                request: request ?? "",
                settings: current,
                withPicture: withPicture,
                selected: selectedID
            ) { choice in
                picked = choice
                selectedID = choice.externalId
            }
        }
    }

    private func shareText(for model: ModelChoice?, times: Int = 1) -> String? {
        guard let model else { return nil }
        let cost = model.externalId == selectedID ? (price ?? model.cost) : model.cost
        return session.usageShare(of: cost).map { UsageFormat.short($0 * Double(times)) }
    }

    // MARK: - Behaviour

    private func start() {
        guard selectedID == nil else { return }
        if prompt.isEmpty { prompt = request ?? "" }
        count = offeredCount
        let usable = offer.options.filter { $0.affordable != false }
        selectedID = [offer.preselect, offer.auto?.externalId]
            .compactMap { $0 }
            .first { id in usable.contains { $0.externalId == id } }
            ?? usable.first?.externalId
            ?? offer.options.first?.externalId
        adoptDefaults(keeping: false)
        price = selected?.cost
        // The first price was asked for the settings Postpilot guessed; if the
        // card starts on different ones, ask again so the button is true.
        if resolution != nil || duration != nil { reprice() }
        if opensAtOnce, !inline, !key.isEmpty, !Self.opened.contains(key) {
            Self.opened.insert(key)
            showing = true
        }
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
        // words, else vertical -- this app makes things for a phone.
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

    /// Everything set on the sheet, as it would be sent. The adapter takes each
    /// of these in that model's own spelling and drops what it does not have.
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
    /// sheet still answers the offer it came from.
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
}

/// Which model: Auto, the offered ones with their share of the month, every
/// model one tap further, and -- for pictures and videos -- "Always use", which
/// sets the default in Create settings so the chat stops asking.
struct PickModelList: View {
    let title: String
    let options: [ModelChoice]
    let auto: ModelChoice?
    let total: Int?
    let capability: String
    @Binding var selectedID: String?
    let price: ModelCost?
    let onBrowse: () -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var always = false

    private var isVideo: Bool { capability == "video_generation" }
    private var keepsDefault: Bool { capability == "image_generation" || capability == "video_generation" }
    private var noun: String { isVideo ? "video" : "picture" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let auto, options.contains(where: { $0.externalId == auto.externalId }) {
                    autoRow(auto)
                }

                PickHeading("Your models · share of your month each")
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        modelButton(option)
                        if index < options.count - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(PickKit.card)

                Button(action: onBrowse) {
                    HStack {
                        Text(total.map { "All \($0) models" } ?? "All models")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                    .background(PickKit.card)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if keepsDefault {
                    PickRow("Always use for \(noun)s") {
                        Toggle("Always use for \(noun)s", isOn: $always)
                            .labelsHidden()
                            .tint(.green)
                    }
                    .padding(.top, 8)
                    Text("On, the chat stops asking and makes every \(noun) with this model. Change it any time in Create settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { always = isDefault }
        .onChange(of: always) { _, on in setDefault(on) }
        .onChange(of: selectedID) { _, _ in
            if always { setDefault(true) }
        }
    }

    private func autoRow(_ auto: ModelChoice) -> some View {
        Button {
            selectedID = auto.externalId
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("The best for the price · \(auto.label)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if selectedID == auto.externalId {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 62)
            .background(PickKit.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelButton(_ option: ModelChoice) -> some View {
        let usable = option.affordable != false
        // A model for a higher plan opens the plans instead of being chosen:
        // the tap is a wish to use it, and the answer is how.
        let lockedTo: String? = option.minimumTier(isVideo: isVideo) > session.planRank
            ? option.unlockedBy(isVideo: isVideo)
            : nil
        let on = selectedID == option.externalId
        let cost = on ? (price ?? option.cost) : option.cost
        return Button {
            if lockedTo != nil {
                session.showingPaywall = true
            } else if usable {
                selectedID = option.externalId
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.body.weight(on ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let lockedTo {
                            Label(lockedTo, systemImage: "lock.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let detail = option.about ?? option.constraints.notes?.first, !detail.isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(usable ? Color.secondary : Color.orange)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                if let share = session.usageShare(of: cost) {
                    Text(UsageFormat.short(share))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if on {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
            .opacity(usable ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!usable && lockedTo == nil)
    }

    private var isDefault: Bool {
        guard let selectedID else { return false }
        let prefs = GeneratorPrefs.current
        return (isVideo ? prefs.videoModel : prefs.imageModel) == selectedID
    }

    private func setDefault(_ on: Bool) {
        var prefs = GeneratorPrefs.current
        let label = options.first { $0.externalId == selectedID }?.label
        if isVideo {
            prefs.videoModel = on ? selectedID : nil
            prefs.videoModelLabel = on ? label : nil
        } else {
            prefs.imageModel = on ? selectedID : nil
            prefs.imageModelLabel = on ? label : nil
        }
        GeneratorPrefs.current = prefs
    }
}
