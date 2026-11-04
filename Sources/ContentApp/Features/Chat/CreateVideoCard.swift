import SwiftUI

/// What "Photo video" on the create card makes: the story engine, with the
/// card's choices. Sent as one action; nothing is typed on the person's behalf.
struct StoryChoice: Equatable, Sendable {
    /// `content_templates.slug`.
    var style: String
    var styleName: String
    var topic: String
    var seconds: Int
    var look: SeriesLook?
    var voice: SeriesVoice?
    var caption: SeriesCaption
    /// What the server read from the request and any pictures sent with it
    /// (`VideoBrief.direction`): tone, pace, structure. Told to the writer.
    var direction: String? = nil

    var payload: [String: Any] {
        var out: [String: Any] = ["type": "story", "topic": topic, "style": style, "seconds": seconds]
        if let look { out["look"] = look.prompt }
        if let direction, !direction.isEmpty { out["direction"] = direction }
        if let voice {
            if voice.isNone { out["narration"] = false }
            if let id = voice.elevenLabsID { out["voiceId"] = id }
        }
        out["captionStyle"] = caption.id
        return out
    }

    /// The card's settled line: what was chosen, in the words on the card.
    var summary: String {
        var parts = ["Photo video", "\(seconds) sec", styleName]
        if let look { parts.append(look.name) }
        if let voice { parts.append(voice.isNone ? "No voiceover" : voice.name) }
        parts.append(caption.isNone ? "No captions" : caption.name)
        return parts.joined(separator: " · ")
    }

    /// What it will cost us, from the first real story (31 Oct 2026: 15 s, six
    /// pictures at about 3.2¢, the voice about 4¢, the writing 2¢). A picture
    /// every three seconds or so, plus the voice. An estimate for the button,
    /// never a charge: each picture is priced and taken as it is made.
    var estimatedUSD: Double {
        let pictures = max(4, Int((Double(seconds) / 3).rounded(.up)))
        let voiceUSD = voice?.isNone == true ? 0 : Double(seconds) * 0.0025
        return Double(pictures) * 0.04 + voiceUSD + 0.02
    }
}

/// What a request already says about the video it wants, so the card asks
/// only for what is missing.
///
/// Abel, 31 Oct 2026: "You don't always have to send a photo or video if the
/// user already explained what he wants ... If the user says, 'Generate 15
/// seconds,' make sure it's only 15 seconds." The card opened on 30 seconds
/// and on the Photo / AI question whatever the request said.
struct VideoAsk: Equatable {
    enum Kind: Equatable { case photo, ai }

    var kind: Kind?
    var seconds: Int?

    /// Shortest and longest a story is made.
    static let range = 5...180

    static func read(_ text: String?) -> VideoAsk {
        guard var t = text?.lowercased(), !t.isEmpty else { return VideoAsk() }
        t = t.replacingOccurrences(of: "’", with: "'")
        // Spoken numbers, as dictation sometimes leaves them. Two-word ones first.
        for (word, n) in [("forty[- ]five", 45), ("ninety", 90), ("sixty", 60), ("fifty", 50), ("forty", 40),
                          ("thirty", 30), ("twenty", 20), ("fifteen", 15), ("ten", 10), ("five", 5),
                          ("three", 3), ("two", 2), ("one", 1)] {
            t = t.replacingOccurrences(of: "\\b\(word)\\b", with: "\(n)", options: .regularExpression)
        }

        var out = VideoAsk()
        let minutes = number(in: t, before: "(m|min|mins|minute|minutes)")
        let seconds = number(in: t, before: "(s|sec|secs|second|seconds)")
        if minutes != nil || seconds != nil {
            out.seconds = Int(((minutes ?? 0) * 60 + (seconds ?? 0)).rounded())
        } else if t.contains("half a minute") || t.contains("half-minute") {
            out.seconds = 30
        } else if t.range(of: #"\ba minute\b|\bminute[- ]long\b"#, options: .regularExpression) != nil {
            out.seconds = 60
        }
        if let s = out.seconds { out.seconds = min(max(s, range.lowerBound), range.upperBound) }

        let ai = t.range(of: #"\bai[- ]?(video|clip)s?\b|\breal (video|clips?|footage|motion)\b|\bvideo model\b|\b(veo|kling|sora|wan|hailuo|seedance|runway|luma|pika|minimax)\b"#,
                         options: .regularExpression) != nil
        let photo = t.range(of: #"\b(photo|picture|image|still)s?[- ]?(video|story|reel)s?\b|\bslide ?show\b|\b(with|from|using|out of) (ai )?(photos|pictures|images|stills)\b"#,
                            options: .regularExpression) != nil
        if ai != photo { out.kind = ai ? .ai : .photo }
        return out
    }

    /// The number in front of a unit: "15 sec", "15-second", "1.5 min".
    private static func number(in text: String, before unit: String) -> Double? {
        guard let r = text.range(of: #"\b\d{1,3}(\.\d)?\s*-?\s*"# + unit + #"\b"#, options: .regularExpression) else { return nil }
        return Double(String(text[r].prefix { $0.isNumber || $0 == "." }))
    }
}

/// The card a request for a video gets.
///
/// Netro, 31 Oct 2026, on the first card: "When you hit it, it's kind of
/// boring, and the screen looks bad." And on the second, with its strip of
/// look pictures and its menus: "The caption and the voice should be with a
/// sheet. A sheet pops up, and on the sheet, you will see what you are
/// choosing." So the card is a short list of rows, each already on an answer
/// -- from the request when it said, else from the series they set up, else a
/// sensible default -- and the pictures, voices and caption styles open in a
/// sheet where they can be seen and heard. Photo or AI is asked only when the
/// request did not say.
struct CreateVideoCard: View {
    let offer: ModelOffer
    let request: String?
    /// What was made, once Create or Generate was pressed. The card then
    /// settles into one line.
    let settled: String?
    /// Photo video is offered only for a plain request: a picture to animate
    /// is a job for a video model.
    let photoAllowed: Bool
    /// A new offer opens its sheet at once, once per `key` (Abel, 4 Nov 2026:
    /// the video gets the same sheet as the picture).
    var opensAtOnce = false
    var key = ""
    let onGenerate: (ModelChoice, GenerationSettings, ModelCost?) -> Void
    let onStory: (StoryChoice) -> Void

    @Environment(AppSession.self) private var session
    @State private var showing = false
    @MainActor private static var opened: Set<String> = []

    @State private var kind: VideoAsk.Kind = .photo
    @State private var templates: [ContentTemplate] = []
    @State private var styleSlug: String?
    @State private var seconds = 30
    @State private var look: SeriesLook?
    @State private var voice: SeriesVoice?
    @State private var caption = SeriesCaption.all[0]
    @State private var sampler = VoiceSampler()
    @State private var sheet: Sheet?
    @State private var prepared = false
    /// The rows behind "Change". With a brief the card opens on its one-line
    /// plan; nothing is shown to choose from until they ask to.
    @State private var editing = false

    private enum Sheet: String, Identifiable {
        case look, voice, caption
        var id: String { rawValue }
    }

    private var ask: VideoAsk { VideoAsk.read(request) }
    /// What the server already decided from the request, if it could.
    private var brief: VideoBrief? { offer.brief }
    /// Photo or AI is a question only when neither the request nor the server
    /// answered it.
    private var asksKind: Bool { photoAllowed && ask.kind == nil && brief == nil }
    private var showsAI: Bool { kind == .ai || !photoAllowed }

    private var style: ContentTemplate? { templates.first { $0.slug == styleSlug } }
    private var looks: [SeriesLook] {
        let own = CategoryLooks.looks(for: styleSlug)
        return own.isEmpty ? SeriesLook.all : own
    }
    private var lengths: [Int] { Array(Set([10, 15, 20, 30, 45, 60, 90, seconds])).sorted() }
    private var choice: StoryChoice? {
        guard let styleSlug else { return nil }
        return StoryChoice(
            style: styleSlug,
            styleName: style?.name ?? styleSlug,
            topic: request ?? "",
            seconds: seconds,
            look: look,
            voice: voice,
            caption: caption,
            direction: brief?.direction
        )
    }

    var body: some View {
        if let settled {
            settledLine(settled)
        } else {
            summary
                .task {
                    if opensAtOnce, !key.isEmpty, !Self.opened.contains(key) {
                        Self.opened.insert(key)
                        showing = true
                    }
                    await prepare()
                }
                .onDisappear { sampler.stop() }
                .sheet(isPresented: $showing, onDismiss: { sampler.stop() }) { videoSheet }
        }
    }

    /// What stays in the chat: one row that opens the sheet again.
    private var summary: some View {
        Button { showing = true } label: {
            HStack(spacing: 12) {
                Image(systemName: showsAI ? "film" : "photo.stack")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(showsAI ? "Video · AI video" : "Video · Photo video")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(showsAI
                         ? "Pick a model, then tap Generate"
                         : choice.map { $0.summary.replacingOccurrences(of: "Photo video · ", with: "") }
                            ?? "Pictures that move, with voice and captions")
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
        .accessibilityHint("Opens the video settings")
    }

    /// The Create settings sheet for a video: Photo or AI on top, then only
    /// what that kind needs.
    private var videoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if photoAllowed { kindPicker }
                    if showsAI {
                        GenerationCard(offer: offer, request: request, settled: nil, inline: true) { choice, settings, price in
                            showing = false
                            onGenerate(choice, settings, price)
                        }
                    } else {
                        photoPanel
                            .padding(14)
                            .background(PickKit.card)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showing = false } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .sheet(item: $sheet, onDismiss: { sampler.stop() }) { which in
                NavigationStack {
                    sheetBody(which)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { sheet = nil }
                            }
                        }
                }
                .presentationDetents(Self.detents(for: which))
                .presentationDragIndicator(.visible)
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(34)
        .presentationDragIndicator(.visible)
    }

    /// Photo video | AI video, as the Create settings pills.
    private var kindPicker: some View {
        HStack(spacing: 2) {
            kindPill(.photo, title: "Photo video")
            kindPill(.ai, title: "AI video")
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .padding(.top, 4)
    }

    private func kindPill(_ which: VideoAsk.Kind, title: String) -> some View {
        let on = kind == which
        return Button {
            withAnimation(.snappy(duration: 0.2)) { kind = which }
            sampler.stop()
        } label: {
            Text(title)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Color(.systemBackground) : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background {
                    if on { Capsule().fill(Color.primary) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: kind)
    }

    // MARK: - Photo video

    /// Whether the card is showing the server's plan as one block, with the
    /// rows tucked behind Change.
    private var showsPlan: Bool { brief != nil && !editing }

    private var photoPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !asksKind && brief == nil {
                // They said "photo video": no question, just what this is.
                VStack(alignment: .leading, spacing: 2) {
                    Label("Photo video", systemImage: "photo.stack")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.primary)
                    Text("Pictures that move, with voice and captions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showsPlan {
                planBlock
            } else {
                VStack(spacing: 0) {
                    lengthRow
                    rowDivider
                    styleRow
                    rowDivider
                    Button { open(.look) } label: {
                        row(title: "Look", value: look?.name ?? "Pick one", chevron: "chevron.right") { lookThumb }
                    }
                    .buttonStyle(.plain)
                    rowDivider
                    Button { open(.voice) } label: {
                        row(title: "Voice", value: voice?.name ?? "Pick one", chevron: "chevron.right") { icon("waveform") }
                    }
                    .buttonStyle(.plain)
                    rowDivider
                    Button { open(.caption) } label: {
                        row(title: "Captions", value: caption.name, chevron: "chevron.right") { icon("captions.bubble") }
                    }
                    .buttonStyle(.plain)
                }
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }
            }

            Button {
                guard let choice, !choice.topic.isEmpty else { return }
                sampler.stop()
                showing = false
                onStory(choice)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(brief == nil ? "Create photo video" : "Make it")
                    if let share = photoShare {
                        Text(share).fontWeight(.medium).opacity(0.85)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .disabled(choice == nil || (request ?? "").isEmpty)

            if showsPlan {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { editing = true }
                } label: {
                    Text("Change something")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }

            Text(brief == nil ? "Nothing is spent until you tap Create." : "Nothing is spent until you tap Make it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    /// The plan the server made from the request, in the card's own words: what
    /// will be made, and one line on why. Everything that can be changed is
    /// behind Change.
    private var planBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Photo video", systemImage: "photo.stack")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.primary)
            if let choice {
                Text(choice.summary.replacingOccurrences(of: "Photo video · ", with: ""))
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = brief?.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private var lengthRow: some View {
        Menu {
            Picker("Length", selection: $seconds) {
                ForEach(lengths, id: \.self) { Text("\($0) sec").tag($0) }
            }
        } label: {
            row(title: "Length", value: "\(seconds) sec",
                note: ask.seconds == seconds ? "as you asked" : nil,
                chevron: "chevron.up.chevron.down") { icon("timer") }
        }
    }

    private var styleRow: some View {
        Menu {
            ForEach(templates) { template in
                Button {
                    pickStyle(template.slug)
                } label: {
                    if template.slug == styleSlug {
                        Label(template.name, systemImage: "checkmark")
                    } else {
                        Text(template.name)
                    }
                }
            }
        } label: {
            row(title: "Style", value: style?.name ?? "Pick one", chevron: "chevron.up.chevron.down") { icon("square.grid.2x2") }
        }
        .disabled(templates.isEmpty)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetBody(_ which: Sheet) -> some View {
        switch which {
        case .look:
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(looks) { item in
                        LookTile(
                            look: item,
                            isChosen: look?.id == item.id,
                            badge: item.id == looks.first?.id ? "Best match" : nil
                        ) {
                            withAnimation(.snappy(duration: 0.18)) { look = item }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            closeSoon(.look)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(style.map { "\($0.name) looks" } ?? "Look")

        case .voice:
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(SeriesVoice.all) { item in
                        VoiceRow(
                            voice: item,
                            isChosen: voice?.id == item.id,
                            isPlaying: sampler.playing == item.id,
                            choose: {
                                withAnimation(.snappy(duration: 0.18)) { voice = item }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            },
                            play: { sampler.toggle(item) }
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("Voice")

        case .caption:
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(SeriesCaption.all) { item in
                        CaptionTile(caption: item, isChosen: caption.id == item.id) {
                            withAnimation(.snappy(duration: 0.18)) { caption = item }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            closeSoon(.caption)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Captions")
        }
    }

    /// Looks are pictures and want the room; voices and captions fit in half.
    private static func detents(for which: Sheet) -> Set<PresentationDetent> {
        which == .look ? [.large] : [.medium, .large]
    }

    private func open(_ which: Sheet) {
        sampler.stop()
        sheet = which
    }

    /// A picked look or caption style closes its sheet after a beat, so the
    /// check is seen landing. Voices stay open: people listen to a few.
    private func closeSoon(_ which: Sheet) {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if sheet == which { sheet = nil }
        }
    }

    // MARK: - Pieces

    private func kindTile(_ which: VideoAsk.Kind, symbol: String, title: String, line: String, price: String) -> some View {
        let on = kind == which
        return Button {
            withAnimation(.snappy(duration: 0.2)) { kind = which }
            sampler.stop()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(on ? Theme.onAccent : Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accent.opacity(0.12)))
                    }
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.primary)
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(price)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(on ? Theme.accent : Color.secondary)
            }
            .multilineTextAlignment(.leading)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                shape.fill(on ? Theme.accent.opacity(0.06) : Color.clear)
                    .overlay(shape.strokeBorder(on ? Theme.accent : Color.primary.opacity(0.12), lineWidth: on ? 2 : 1))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }

    private func switchLink(to which: VideoAsk.Kind) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { kind = which }
            sampler.stop()
        } label: {
            Text(which == .ai ? "Make it an AI video instead" : "Make it a photo video instead")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func row<Leading: View>(
        title: String,
        value: String,
        note: String? = nil,
        chevron: String?,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: 12) {
            leading()
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let chevron {
                Image(systemName: chevron)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.12)))
    }

    /// The chosen look's own picture, small, so the row shows it.
    @ViewBuilder
    private var lookThumb: some View {
        if let look, let image = UIImage(named: look.artName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            icon("paintpalette")
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 52)
    }

    private func settledLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.surface)
        }
    }

    private var photoShare: String? {
        guard let choice, let share = session.usageShare(usd: choice.estimatedUSD) else { return nil }
        return "· about \(UsageFormat.percent(share))"
    }

    private var photoPriceLine: String {
        guard let choice, let share = session.usageShare(usd: choice.estimatedUSD) else { return "About half the price" }
        return "About \(UsageFormat.percent(share)) of your month"
    }

    // MARK: - Starting answers

    /// Each row starts on an answer, strongest first: what the request said in
    /// so many words, then what the server decided from the whole request (the
    /// pictures sent, the account, the series), then what their series was set
    /// up with, then the style's defaults.
    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        let ask = self.ask
        let plan = session.plan
        let brief = self.brief
        if let said = ask.kind {
            kind = photoAllowed ? said : .ai
        } else if let brief {
            kind = brief.isPhoto ? .photo : .ai
        }
        if let said = ask.seconds {
            seconds = said
        } else if let decided = brief?.seconds, VideoAsk.range.contains(decided) {
            seconds = decided
        } else if let series = plan?.durationSeconds, VideoAsk.range.contains(series) {
            seconds = series
        }

        let loaded = await session.templates()
        templates = loaded
        let text = (request ?? "").lowercased()
        let named = loaded.first { Self.mentions(text, style: $0) }
        let fromBrief = loaded.first { $0.slug == brief?.style }
        let fromSeries = loaded.first { $0.slug == plan?.templateSlug }
        let saved = loaded.first { $0.slug == session.settings?.styleSlug }
        pickStyle((named ?? fromBrief ?? fromSeries ?? saved ?? loaded.first)?.slug ?? brief?.style)

        if let plan {
            if let id = plan.voiceID, let match = SeriesVoice.all.first(where: { $0.elevenLabsID == id }) {
                voice = match
            } else if let said = plan.voice, let match = SeriesVoice.all.first(where: { $0.sentence == said }) {
                voice = match
            }
            if let match = SeriesCaption.all.first(where: { $0.id == plan.captionStyle }) { caption = match }
            if plan.templateSlug == styleSlug, let saved = plan.look,
               let match = looks.first(where: { saved == $0.sentence || saved.hasPrefix("\($0.name) --") }) {
                look = match
            }
        }
        // The server read the whole request, and the series too: its answers
        // are the more specific of the two.
        if let id = brief?.voice, let match = SeriesVoice.all.first(where: { $0.id == id }) { voice = match }
        if let id = brief?.captions, let match = SeriesCaption.all.first(where: { $0.id == id }) { caption = match }
        if let custom = brief?.customLook { look = custom }
        // A look they named in the request wins over everything.
        if let match = looks.first(where: { text.contains($0.name.lowercased()) }) { look = match }
    }

    /// Whether the request names this style: its slug ("scary"), or the first
    /// word of its name when that word is distinctive ("motivation").
    static func mentions(_ text: String, style template: ContentTemplate) -> Bool {
        let slug = NSRegularExpression.escapedPattern(for: template.slug.lowercased())
        if text.range(of: "\\b\(slug)\\b", options: .regularExpression) != nil { return true }
        guard let first = template.name.lowercased().split(separator: " ").first.map(String.init), first.count >= 5 else { return false }
        return text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: first))", options: .regularExpression) != nil
    }

    private func pickStyle(_ slug: String?) {
        guard let slug else { return }
        let changed = slug != styleSlug
        styleSlug = slug
        if changed || look == nil || !looks.contains(where: { $0.id == look?.id }) { look = looks.first }
        let template = templates.first { $0.slug == slug }
        // Stories are told by the storyteller; everything else starts calm.
        let preferred = template?.category == "Stories" ? "storyteller" : "calm_male"
        if voice == nil || voice?.id == "storyteller" || voice?.id == "calm_male" {
            voice = SeriesVoice.all.first { $0.id == preferred }
        }
    }
}
