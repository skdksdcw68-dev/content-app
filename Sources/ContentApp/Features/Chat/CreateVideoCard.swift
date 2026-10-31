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

    var payload: [String: Any] {
        var out: [String: Any] = ["type": "story", "topic": topic, "style": style, "seconds": seconds]
        if let look { out["look"] = look.prompt }
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

    /// A picture every few seconds at the house image rate, plus the voice.
    /// An estimate for the button, never a charge: each picture is priced and
    /// taken as it is made.
    var estimatedUSD: Double {
        let pictures = max(4, Int((Double(seconds) / 4).rounded(.up)))
        let voiceUSD = voice?.isNone == true ? 0 : Double(seconds) * 0.0035
        return Double(pictures) * 0.07 + voiceUSD
    }
}

/// The card a request for a video gets: Photo video or AI video, side by side.
///
/// Netro, 31 Oct 2026, on the old card: "When you hit it, it's kind of boring,
/// and the screen looks bad. Make a perfect one." And: "when I ask you to make
/// me a video, you also can make it using pictures or photos." So the choice
/// a person actually makes comes first, as two pictures; the photo video's few
/// choices are rows with sensible answers already in them; and AI video keeps
/// the full model card, because there the model really is the decision.
struct CreateVideoCard: View {
    let offer: ModelOffer
    let request: String?
    /// What was made, once Create or Generate was pressed. The card then
    /// settles into one line.
    let settled: String?
    /// Photo video is offered only for a plain request: a picture to animate
    /// is a job for a video model.
    let photoAllowed: Bool
    let onGenerate: (ModelChoice, GenerationSettings, ModelCost?) -> Void
    let onStory: (StoryChoice) -> Void

    @Environment(AppSession.self) private var session

    private enum Kind { case photo, ai }
    @State private var kind: Kind = .photo
    @State private var templates: [ContentTemplate] = []
    @State private var styleSlug: String?
    @State private var seconds = 30
    @State private var look: SeriesLook?
    @State private var voice: SeriesVoice?
    @State private var caption = SeriesCaption.all[0]
    @State private var sampler = VoiceSampler()

    private var style: ContentTemplate? { templates.first { $0.slug == styleSlug } }
    private var looks: [SeriesLook] {
        let own = CategoryLooks.looks(for: styleSlug)
        return own.isEmpty ? SeriesLook.all : own
    }
    private var choice: StoryChoice? {
        guard let styleSlug else { return nil }
        return StoryChoice(
            style: styleSlug,
            styleName: style?.name ?? styleSlug,
            topic: request ?? "",
            seconds: seconds,
            look: look,
            voice: voice,
            caption: caption
        )
    }

    var body: some View {
        if let settled {
            settledLine(settled)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if photoAllowed {
                    HStack(spacing: 10) {
                        kindTile(.photo, symbol: "photo.stack", title: "Photo video",
                                 line: "Pictures that move, with voice and captions", price: photoPriceLine)
                        kindTile(.ai, symbol: "film", title: "AI video",
                                 line: "Real moving clips from a video model", price: "Video model price")
                    }
                }

                if kind == .ai || !photoAllowed {
                    GenerationCard(offer: offer, request: request, settled: nil, onGenerate: onGenerate)
                } else {
                    photoPanel
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.surface)
            }
            .task { await loadStyles() }
            .onDisappear { sampler.stop() }
        }
    }

    // MARK: - Photo video

    private var photoPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("LENGTH")
                Picker("Length", selection: $seconds) {
                    ForEach([15, 30, 60], id: \.self) { Text("\($0) sec").tag($0) }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("LOOK")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(looks) { item in
                            LookTile(
                                look: item,
                                isChosen: look?.id == item.id,
                                badge: item.id == looks.first?.id ? "Best match" : nil
                            ) {
                                withAnimation(.snappy(duration: 0.18)) { look = item }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            .frame(width: 150)
                        }
                    }
                }
                .scrollClipDisabled()
            }

            VStack(spacing: 0) {
                styleRow
                Divider().padding(.leading, 52)
                voiceRow
                Divider().padding(.leading, 52)
                captionRow
            }
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }

            Button {
                guard let choice, !choice.topic.isEmpty else { return }
                sampler.stop()
                onStory(choice)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Create photo video")
                    if let share = photoShare {
                        Text(share).fontWeight(.medium).opacity(0.85)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RemiFilledButtonStyle())
            .disabled(choice == nil || (request ?? "").isEmpty)

            Text("Nothing is spent until you tap Create.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
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
            row(symbol: "square.grid.2x2", title: "Style", value: style?.name ?? "Pick one", chevron: "chevron.up.chevron.down")
        }
        .disabled(templates.isEmpty)
    }

    private var voiceRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(SeriesVoice.all) { item in
                    Button {
                        sampler.stop()
                        voice = item
                    } label: {
                        if item.id == voice?.id {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
            } label: {
                row(symbol: "waveform", title: "Voice", value: voice?.name ?? "Pick one", chevron: nil)
            }

            // Heard inside the row it belongs to, not floating beside it.
            if let voice, voice.sample != nil {
                let playing = sampler.playing == voice.id
                Button { sampler.toggle(voice) } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(playing ? Theme.onAccent : Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(playing ? Theme.accent : Theme.accent.opacity(0.14)))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressButtonStyle())
                .padding(.trailing, 8)
                .accessibilityLabel(playing ? "Stop \(voice.name)" : "Hear \(voice.name)")
            }
        }
    }

    private var captionRow: some View {
        Menu {
            ForEach(SeriesCaption.all) { item in
                Button {
                    caption = item
                } label: {
                    if item.id == caption.id {
                        Label("\(item.name) -- \(item.detail)", systemImage: "checkmark")
                    } else {
                        Text("\(item.name) -- \(item.detail)")
                    }
                }
            }
        } label: {
            row(symbol: "captions.bubble", title: "Captions", value: caption.name, chevron: "chevron.up.chevron.down")
        }
    }

    // MARK: - Pieces

    private func kindTile(_ which: Kind, symbol: String, title: String, line: String, price: String) -> some View {
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

    private func row(symbol: String, title: String, value: String, chevron: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.12)))
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
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

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
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

    // MARK: - Defaults

    /// Opens on the style the person chose in Start a series, with that
    /// style's best look and a voice that suits it.
    private func loadStyles() async {
        guard templates.isEmpty else { return }
        let loaded = await session.templates()
        templates = loaded
        if styleSlug == nil {
            let saved = session.settings?.styleSlug
            pickStyle(loaded.first { $0.slug == saved }?.slug ?? loaded.first?.slug)
        }
    }

    private func pickStyle(_ slug: String?) {
        guard let slug else { return }
        styleSlug = slug
        look = looks.first
        let template = templates.first { $0.slug == slug }
        // Stories are told by the storyteller; everything else starts calm.
        let preferred = template?.category == "Stories" ? "storyteller" : "calm_male"
        if voice == nil || voice?.id == "storyteller" || voice?.id == "calm_male" {
            voice = SeriesVoice.all.first { $0.id == preferred }
        }
    }
}
