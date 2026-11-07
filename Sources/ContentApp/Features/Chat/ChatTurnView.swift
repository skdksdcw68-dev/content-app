import SwiftUI
import TipKit
import UIKit

/// One turn. The user's is a tinted capsule pushed right; the agent's is
/// typography on the page -- which is how every assistant on the platform
/// reads. Boxing a long answer makes it look like a quotation rather than a
/// reply.
struct ChatTurnView: View {
    let turn: ChatMessage
    /// The words of a message opened to be selected piece by piece.
    @State private var selecting: String?
    /// The pictures of a set still being made, for "2 of 4 ready". Only runs
    /// seen working count: a reopened chat's finished set shows no line.
    @State private var liveRuns: Set<UUID> = []
    /// Answering a question is the same as saying it out loud, so it goes back
    /// as an ordinary turn rather than through a side channel. The transcript
    /// then reads the way the conversation actually went.
    var onAnswer: (ChatQuestion, String) -> Void = { _, _ in }
    /// Generate was pressed on a card: this model, these settings, at the
    /// price the card showed.
    var onGenerate: (ModelChoice, GenerationSettings, ModelCost?) -> Void = { _, _, _ in }
    /// "Create photo video" on the create card.
    var onStory: (StoryChoice) -> Void = { _ in }
    var onExport: (Artifact, String) -> Void = { _, _ in }
    var onAnimate: (Artifact) -> Void = { _ in }
    var onApprove: (Artifact) -> Void = { _ in }
    /// A picture picked as the reference for whatever is asked next.
    var onReference: ((Artifact) -> Void)? = nil
    /// A run this turn started has ended while it was being watched.
    var onRunFinished: (UUID) -> Void = { _ in }
    /// A suggested next thing, tapped.
    var onSuggest: (String) -> Void = { _ in }
    /// Like or dislike, with a reason for a dislike.
    var onRate: (String, String?) -> Void = { _, _ in }
    /// Ask again for a different answer. Nil when that is not possible here.
    var onRegenerate: (() -> Void)? = nil
    /// The reply failed: ask again, with the same words.
    var onRetryFailed: (() -> Void)? = nil
    /// One-tap ideas under a picture belong to the moment it was made. Once
    /// something else has been said they are stale, and are not drawn (Abel,
    /// 2 Nov 2026: "once they sent another text, the recommendation should be
    /// removed").
    var showsSuggestions = true
    /// The first rated-able answer carries the one-time tip.
    var showsActionsTip = false

    /// Two pictures a row, for a set made from one request.
    private static let grid = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    /// A set of pictures: how many are ready, then one frame per picture,
    /// each going when its own picture is done.
    @ViewBuilder
    private var pictureSet: some View {
            if !liveRuns.isEmpty {
                HStack {
                    Text("Creating \(turn.runIds.count) pictures")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text("\(turn.runIds.count - liveRuns.count) of \(turn.runIds.count) ready")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.subheadline)
                .animation(.snappy(duration: 0.2), value: liveRuns.count)
            }
            LazyVGrid(columns: Self.grid, spacing: 6) {
                ForEach(turn.runIds, id: \.self) { id in
                    RunCard(
                        runId: id,
                        kind: turn.runKind,
                        expectedKind: "image",
                        tile: true,
                        onFinished: { onRunFinished(id) },
                        onLive: { live in
                            if live { liveRuns.insert(id) } else { liveRuns.remove(id) }
                        }
                    )
                }
            }
    }

    /// The pictures this turn shows: a whole set, or the one picture.
    private var pictureIds: [UUID] {
        if turn.batchArtifacts.count > 1 { return turn.batchArtifacts }
        if turn.artifactKind == "image", let id = turn.artifactId { return [id] }
        return []
    }

    var body: some View {
        switch turn.role {
        case .user where turn.isTap:
            // A tap, not a sentence: the card or chip it came from has already
            // settled on what was chosen, so there is nothing to draw here.
            EmptyView()
        case .assistant where turn.isProgress:
            // A job's steps, folded into one block by the conversation.
            ProgressBlock(
                steps: turn.progressSteps.isEmpty ? [turn.text] : turn.progressSteps,
                live: turn.progressLive,
                started: turn.progressStarted,
                ended: turn.progressEnded
            )
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !turn.attachments.isEmpty {
                    // Their pictures sit on their side, above what they said.
                    AttachmentStrip(paths: turn.attachments, trailing: true)
                }
                // A photo sent on its own has no words; an empty capsule under
                // it would read as a message that failed to send.
                if !turn.text.isEmpty {
                    // A video they sent rides in the message as its words; the
                    // bubble shows what they typed and the transcript folded.
                    let parts = Transcript.split(turn.text)
                    if !parts.typed.isEmpty {
                        HStack {
                            Spacer(minLength: 44)
                            Text(parts.typed)
                                .font(.body)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Theme.accent.opacity(0.10))
                                }
                                // Holding a message: copy it whole, or open it to pick
                                // words out. SwiftUI's own selection did nothing in the
                                // scrolling chat.
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = parts.typed
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    Button {
                                        selecting = parts.typed
                                    } label: {
                                        Label("Select text", systemImage: "text.cursor")
                                    }
                                }
                        }
                        .sheet(isPresented: Binding(get: { selecting != nil }, set: { if !$0 { selecting = nil } })) {
                            SelectTextSheet(text: selecting ?? "")
                        }
                    }
                    if let transcript = parts.transcript {
                        TranscriptBlock(text: transcript)
                    }
                }
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                if turn.isPending && turn.text.isEmpty {
                    // A dot while it thinks; a line only while it is doing
                    // real work -- making, pricing, researching. Nothing is
                    // announced for an ordinary answer.
                    if let searching = turn.searching {
                        SearchingLine(text: searching, sites: turn.searchSites)
                    } else if turn.steps.isEmpty {
                        ThinkingIndicator(thought: turn.thought, sending: turn.delivery == .sent)
                    } else {
                        LiveThinking(read: turn.thought, steps: turn.steps)
                    }
                } else if turn.failed {
                    // No error in red, no reason. Whatever went wrong, what a
                    // person can do about it is the same: try again (Abel,
                    // 2 Nov 2026: "just tell them to retry, a retry button").
                    Button {
                        onRetryFailed?()
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("That didn't go through")
                } else {
                    // Once the answer lands its steps fold into one quiet
                    // "Thinking ›" above it, and the sheet behind it lists what
                    // was done (Abel, 3 Nov 2026, of Grok's "Thoughts": "so the
                    // user can see what it does with a sheet"). Only on a reply
                    // that did real work -- a "hi" has no line, so this is not
                    // the agent narrating every answer.
                    if turn.hasThinking {
                        ThinkingRow(read: turn.thought, steps: turn.steps, seconds: turn.thinkingSeconds)
                    }
                    if !turn.text.isEmpty, turn.artifactKind == "image" {
                        // A picture's line is a quiet label above it, the way
                        // ChatGPT says "Image created" -- the picture is the
                        // answer, not the sentence.
                        Text(turn.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if !turn.text.isEmpty {
                        // Drawn the way ChatGPT draws an answer -- headings, bold,
                        // lists, a table -- with its text still one selectable run,
                        // so part of it can be picked out and copied.
                        MarkdownText(text: turn.text)
                    }

                    if let offer = turn.offer {
                        if offer.capability == "video_generation" {
                            // Photo video or AI video, side by side -- unless a
                            // picture is to be animated, which only a video
                            // model can do.
                            CreateVideoCard(
                                offer: offer,
                                request: turn.offerRequest,
                                settled: turn.chosenModel,
                                photoAllowed: offer.withPicture != true && turn.offerReferences.isEmpty,
                                opensAtOnce: turn.offerIsNew,
                                key: turn.id.uuidString,
                                onGenerate: { choice, settings, price in onGenerate(choice, settings, price) },
                                onStory: onStory
                            )
                        } else {
                            GenerationCard(
                                offer: offer,
                                request: turn.offerRequest,
                                settled: turn.chosenModel,
                                opensAtOnce: turn.offerIsNew,
                                key: turn.id.uuidString
                            ) { choice, settings, price in
                                onGenerate(choice, settings, price)
                            }
                        }
                    }

                    if !turn.voices.isEmpty {
                        VoicesCard(voices: turn.voices)
                    }

                    if let scheduleId = turn.scheduleId {
                        ScheduleCard(scheduleId: scheduleId, opensAtOnce: turn.scheduleIsNew)
                    }

                    if let chart = turn.chart {
                        ChatChartCard(chart: chart)
                    }

                    if let platform = turn.connectPlatform {
                        ChatConnectCard(platform: platform) {
                            onSuggest(turn.connectQuestion ?? "How is my \(platform.networkName) doing?")
                        }
                    }

                    ForEach(turn.questions) { question in
                        QuestionCard(
                            question: question,
                            answer: turn.answered[question.key]
                        ) { onAnswer(question, $0) }
                    }

                    if turn.runIds.count > 1 {
                        // A set of pictures: one frame per picture, each going
                        // when its own picture is done, with how many are ready.
                        pictureSet
                    } else if let runId = turn.runId {
                        RunCard(runId: runId, kind: turn.runKind, expectedKind: turn.artifactKind) { onRunFinished(runId) }
                    }

                    if turn.batchArtifacts.count > 1 {
                        LazyVGrid(columns: Self.grid, spacing: 6) {
                            ForEach(turn.batchArtifacts, id: \.self) { id in
                                ArtifactCard(
                                    artifactId: id,
                                    expect: ("image", turn.artifactWidth, turn.artifactHeight),
                                    onAnimate: onAnimate,
                                    onReference: onReference,
                                    tile: true
                                )
                            }
                        }
                    } else if let artifactId = turn.artifactId {
                        ArtifactCard(
                            artifactId: artifactId,
                            expect: (turn.artifactKind, turn.artifactWidth, turn.artifactHeight),
                            onExport: onExport,
                            onAnimate: onAnimate,
                            onApprove: onApprove,
                            onReference: onReference
                        )
                    }

                    // What to say next, as taps -- the answer to a photo
                    // arriving with no words.
                    // Under answers only. A turn that starts a job just says
                    // it has started; the job's result gets the row. Pictures
                    // get Grok's row: save, share, like, make more, and what
                    // they used.
                    if !turn.text.isEmpty, turn.runId == nil {
                        if !pictureIds.isEmpty {
                            PictureActions(
                                ids: pictureIds,
                                rating: turn.rating,
                                onRate: onRate,
                                onAgain: {
                                    onSuggest(pictureIds.count > 1 ? "Make \(pictureIds.count) more like these" : "Make another one like this")
                                }
                            )
                        } else {
                            ReplyActions(
                                text: turn.text,
                                sources: turn.sources,
                                rating: turn.rating,
                                onRate: onRate,
                                onRegenerate: onRegenerate,
                                showsTip: showsActionsTip
                            )
                        }
                    }

                    // What to say next, as Grok's rows under the answer: "↪ in
                    // winter colours". Once one is tapped the list settles on
                    // it -- the tap sent no bubble, so this is where it shows.
                    if !turn.suggestions.isEmpty, showsSuggestions {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(turn.suggestions.enumerated()), id: \.element) { index, suggestion in
                                let picked = turn.suggestionPicked == suggestion
                                let settled = turn.suggestionPicked != nil
                                Button { onSuggest(suggestion) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: picked ? "checkmark" : "arrow.turn.down.right")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(picked ? Theme.accent : Color.secondary)
                                            .frame(width: 18)
                                        Text(suggestion.trimmingCharacters(in: .whitespaces))
                                            .font(.subheadline)
                                            .foregroundStyle(Color.primary)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                    .opacity(settled && !picked ? 0.45 : 1)
                                }
                                .buttonStyle(PressButtonStyle())
                                .disabled(settled)
                                if index < turn.suggestions.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Copy, like, dislike, try again, share -- the row under an answer, the way
/// every assistant app has it. Quiet grey icons that only colour when used.
private struct ReplyActions: View {
    let text: String
    /// The pages a web answer used; the row ends in a Sources pill when any.
    let sources: [WebSource]
    let rating: String?
    let onRate: (String, String?) -> Void
    let onRegenerate: (() -> Void)?
    let showsTip: Bool

    @State private var copied = false
    @State private var askingWhy = false
    private let tip = ReplyActionsTip()

    private static let reasons = [
        "Not accurate",
        "Made something up",
        "Didn't do what I asked",
        "Too long",
        "Not helpful",
    ]

    var body: some View {
        HStack(spacing: 20) {
            Button {
                UIPasteboard.general.string = text
                withAnimation(.snappy(duration: 0.2)) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(.snappy(duration: 0.2)) { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(copied ? "Copied" : "Copy")
            .sensoryFeedback(.success, trigger: copied) { _, now in now }

            Button {
                onRate("up", nil)
            } label: {
                Image(systemName: rating == "up" ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(rating == "up" ? Color.primary : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel("Good answer")
            .popoverTip(showsTip ? tip : nil, arrowEdge: .top)

            Button {
                askingWhy = true
            } label: {
                Image(systemName: rating == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .foregroundStyle(rating == "down" ? Color.primary : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel("Bad answer")
            .confirmationDialog("What was wrong?", isPresented: $askingWhy, titleVisibility: .visible) {
                ForEach(Self.reasons, id: \.self) { reason in
                    Button(reason) { onRate("down", reason) }
                }
                Button("Just rate it") { onRate("down", nil) }
                Button("Cancel", role: .cancel) {}
            }

            if let onRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Try again")
            }

            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")

            if !sources.isEmpty {
                SourcesButton(sources: sources)
            }

            Spacer(minLength: 0)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .buttonStyle(PressButtonStyle())
        .sensoryFeedback(.selection, trigger: rating)
        .padding(.top, 2)
    }
}

/// "Sources" at the end of the row under a web answer, with the logos of the
/// first sites -- ChatGPT's pill. Tapping it lists every page.
private struct SourcesButton: View {
    let sources: [WebSource]

    @State private var open = false

    private var sites: [String] {
        var seen: [String] = []
        for source in sources where !seen.contains(source.site) { seen.append(source.site) }
        return seen
    }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                SiteIcons(domains: sites, size: 16, limit: 3)
                Text("Sources")
                    .font(.footnote.weight(.medium))
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .accessibilityLabel("Sources, \(sites.count) sites")
        .sheet(isPresented: $open) {
            SourcesSheet(sources: sources)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// Every page a web answer used: the site, then the page's title. Tapping one
/// opens it in Safari.
private struct SourcesSheet: View {
    let sources: [WebSource]

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sources")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 8)

            List(sources) { source in
                Button {
                    if let url = URL(string: source.url) { openURL(url) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        SiteIcon(domain: source.site, size: 20)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.site)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(source.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the page")
            }
            .listStyle(.plain)
        }
    }
}

/// One question, with the taps that answer it.
///
/// This is the visible half of the rule that a month of content does not get
/// built until somebody has said what it is for. The agent asks two or three
/// things it genuinely does not know — never what the brand already says — and
/// waits.
///
/// Once answered it settles into the answer rather than disappearing. A card
/// that vanishes leaves the conversation reading as though nothing was asked,
/// and the person cannot see what they agreed to.
private struct QuestionCard: View {
    let question: ChatQuestion
    let answer: String?
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.prompt)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if let answer {
                Label(label(for: answer), systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.accent)
            } else if question.options.isEmpty {
                // Nothing to tap, so say what to do instead of showing an empty
                // row where buttons obviously belong.
                Text("Type your answer below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowRow(spacing: 8) {
                    ForEach(question.options) { option in
                        Button { onPick(option.value) } label: {
                            Text(option.label)
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background {
                                    Capsule().fill(Theme.accent.opacity(0.10))
                                }
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(PressButtonStyle())
                    }
                }

                if question.allowsFreeText {
                    Text("Or type your own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.surface)
        }
    }

    /// The label if the answer came from a button, the raw text if it was typed.
    private func label(for value: String) -> String {
        question.options.first { $0.value == value }?.label ?? value
    }
}

/// Wraps its children onto as many lines as they need.
///
/// `HStack` would push four chips off the edge and `ScrollView(.horizontal)`
/// hides the last one behind an edge nobody thinks to drag. Options are a set
/// to choose from, so all of them have to be visible at once.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// The work, while it is happening.
///
/// The steps arrive as they are taken, each one ticks when it is finished, and
/// the open one pulses. Nothing here composes its own wording: every line is a
/// `TaskStep` the server sent after doing the thing it describes, so the trail
/// cannot claim work that did not happen. That is the difference between
/// showing your work and animating a spinner with ambitions.
struct TaskTrail: View {
    let steps: [TaskStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    marker(for: step)
                        .frame(width: 14, height: 14)

                    Text(step.detail)
                        .font(.subheadline)
                        .foregroundStyle(step.isDone ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func marker(for step: TaskStep) -> some View {
        if step.isDone {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.accent)
        } else {
            PulsingDot()
        }
    }
}

/// The one step still running. Deliberately not a spinner: a spinner says
/// "waiting", and the line beside this already says what for.
private struct PulsingDot: View {
    var body: some View {
        BreathingDot(size: 8)
    }
}

/// One breathing dot while the reply is on its way.
///
/// It used to say "Thinking" with three dots after it, on every message --
/// a word for something that takes a second, repeated until it read as the
/// app talking about itself. A dot says the same thing without saying it.
///
/// It was blue; it is Remi's black-and-white coach dot now, following "Remi
/// colours for everything" (15 Sep 2026).
///
/// 🔴 It is a word again, and it does not move. Abel, 2 Nov 2026: "make the
/// thing think instead of the pill pushing up and down" -- the dot grew and
/// shrank under the words coming. This is the word "Thinking" with light
/// passing over it, fixed in size, and tapping it opens what the server took
/// the message to mean (his reference: Grok).
struct ThinkingIndicator: View {
    /// What the server read the request as, once it has said.
    var thought: String?
    /// The message has left the phone but the server has not answered yet.
    var sending = false

    @State private var sweep: CGFloat = -0.4
    @State private var opened = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Abel, 7 Nov 2026 (the Telegram way): the dot from the tap until the
        // server has the message -- it stays as long as the connection takes
        // -- and then the word "Thinking". Nothing is faked: offline, the dot
        // just stays, and a timeout says so as before.
        if sending {
            // The pill we already had: the breathing dot.
            BreathingDot(size: 10)
                .padding(.vertical, 4)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
        } else {
            thinking
        }
    }

    private var thinking: some View {
        Button { opened = true } label: {
            ZStack {
                Text("Thinking")
                    .foregroundStyle(.secondary.opacity(0.55))
                Text("Thinking")
                    .foregroundStyle(.primary)
                    .mask {
                        GeometryReader { proxy in
                            LinearGradient(
                                colors: [.clear, .white, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: proxy.size.width * 0.5)
                            .offset(x: proxy.size.width * sweep)
                        }
                    }
            }
            .font(.body)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Nothing to open until the server has said what it is working out.
        .disabled(thought == nil)
        .onAppear {
            guard !reduceMotion else { sweep = 0.3; return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { sweep = 1.0 }
        }
        .sheet(isPresented: $opened) {
            ThinkingSheet(read: thought, steps: [], seconds: nil, working: true)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .accessibilityLabel("Thinking")
        .accessibilityHint("Shows what I'm working out")
    }
}

/// "Searching the web" while a web answer looks things up -- ChatGPT's line:
/// a globe, the words with light passing over them, and the logos of the sites
/// read so far, arriving as each search finishes. It gives way to the answer.
private struct SearchingLine: View {
    let text: String
    let sites: [String]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            ShimmerText(text: text, font: .subheadline)
            if !sites.isEmpty {
                SiteIcons(domains: sites, size: 18, limit: 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .font(.subheadline)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sites.isEmpty ? text : "\(text), \(sites.count) sites so far")
    }
}

/// The steps while they are being taken, tappable for the same sheet the
/// finished reply has. The sheet fills in live: it is drawn from the same
/// steps as the trail.
private struct LiveThinking: View {
    let read: String?
    let steps: [TaskStep]

    @State private var opened = false

    var body: some View {
        Button { opened = true } label: {
            TaskTrail(steps: steps)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $opened) {
            ThinkingSheet(read: read, steps: steps, seconds: nil, working: true)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .accessibilityHint("Shows what I'm doing")
    }
}

/// "Thinking ›" above a finished reply that did real work, as Grok's
/// "Thoughts ›". Tapping it opens what was done.
private struct ThinkingRow: View {
    let read: String?
    let steps: [TaskStep]
    let seconds: Int?

    @State private var opened = false

    var body: some View {
        Button { opened = true } label: {
            HStack(spacing: 4) {
                Text("Thinking")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $opened) {
            ThinkingSheet(read: read, steps: steps, seconds: seconds, working: false)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .accessibilityLabel("Thinking")
        .accessibilityHint("Shows what I did for this answer")
    }
}

/// What it did, step by step, in the words the server reported after doing
/// each thing -- nothing invented to fill the space (Grok's "Thoughts" sheet:
/// a tick per step, "Done" at the end). What it took the request to mean sits
/// first, in a box, because it is the router's reading rather than an action.
private struct ThinkingSheet: View {
    let read: String?
    let steps: [TaskStep]
    let seconds: Int?
    /// The reply is still being worked on: the open step pulses and the last
    /// line says so instead of "Done".
    let working: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("Thinking")
                .font(.headline)
                .padding(.top, 24)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let read, !read.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            line("What I took you to mean", done: true)
                            Text(read)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                }
                                .padding(.leading, 26)
                        }
                    }

                    ForEach(steps) { step in
                        line(step.detail, done: step.isDone || !working)
                    }

                    if working {
                        line(read == nil && steps.isEmpty ? "Reading your message" : "Working", done: false)
                    } else {
                        line(seconds.map { "Done in \(Self.duration($0))" } ?? "Done", done: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
    }

    private func line(_ text: String, done: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                } else {
                    PulsingDot()
                }
            }
            .frame(width: 14, height: 14)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "6s", "1m 05s".
    private static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }
}

/// A video they sent, as the words in it, folded so a long speech is not a wall.
private struct TranscriptBlock: View {
    let text: String
    @State private var open = false

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
                } label: {
                    Label(open ? "Video transcript" : "Video transcript · tap to read", systemImage: "text.bubble")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(open ? nil : 3)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// A message's words on their own, in a sheet, where a word or a sentence can be
/// picked out with the usual handles and copied.
private struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                SelectableText(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("Select text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
