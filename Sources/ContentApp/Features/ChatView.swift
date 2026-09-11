import PhotosUI
import SwiftUI
import UIKit

/// The agent, as a conversation.
///
/// This replaced a form: one text field that returned three idea cards and
/// forgot everything the moment it did. That could not be asked a follow-up,
/// could not say "I don't know that about your brand", and showed a spinner for
/// the whole time it worked.
///
/// The shape here is the platform's: turns down the page, the user's tinted and
/// pushed right, the agent's set as prose on the page. The input rides the
/// keyboard from UIKit rather than from SwiftUI's safe area -- see
/// `KeyboardAttachedBar` for the two approaches that did not hold. Tokens are
/// coalesced before they are drawn, so a fast reply does not rebuild the list
/// eighty times a second.
///
/// Planning thirty days is deliberately NOT done here. It is a minute or more
/// of model time and belongs to `propose-plan`, so the agent offers it as an
/// action and the sheet does the work.
struct ChatView: View {
    /// A saved conversation to reopen. Nil starts a new one.
    var threadId: UUID? = nil

    @Environment(AppSession.self) private var session

    @State private var turns: [ChatMessage] = []
    @State private var draft = ""
    @State private var isWorking = false
    @State private var showsOptions = false
    @State private var planning = false
    @State private var proposed: PlanProposal?
    @State private var showingPlan = false
    /// Reported by the attached bar: its own height, so the conversation leaves
    /// room for it and the empty page centres above it.
    @State private var barHeight: CGFloat = 54
    @State private var composerReset = 0
    @State private var composerFocus = 0
    /// The reply in flight, so the stop button has something to stop.
    @State private var work: Task<Void, Never>?
    /// The conversation being written to, once the server has said which.
    @State private var thread: UUID?
    /// Pictures waiting to go with the next message.
    @State private var pending: [PendingAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsPhotoPicker = false
    /// Set when "Attach a photo" is picked, and acted on once the plus sheet
    /// has finished closing -- a picker presented during the dismissal is
    /// dropped, and the button then looks broken.
    @State private var pickAfterDismiss = false
    /// Runs whose ending this conversation has already pulled in, so each is
    /// pulled in once.
    @State private var finishedRuns: Set<UUID> = []
    /// A run ended while a reply was streaming; reload once it is done.
    @State private var reloadWhenIdle = false

    /// The message just sent, held at the top of the screen while its reply
    /// arrives underneath -- ChatGPT's way. Nil when the conversation was
    /// opened rather than added to; then it simply sits at the bottom.
    @State private var pinned: ChatMessage.ID?
    /// Set by `send` so the next new turn scrolls the sent message to the top
    /// instead of scrolling to the end.
    @State private var scrollsToPinned = false
    /// Where the pinned message starts inside the conversation, and how tall
    /// the conversation is: together, how much of it is from there down. Nil
    /// until measured, which leaves a full screen of room so the first scroll
    /// always has somewhere to go.
    @State private var pinnedTop: CGFloat?
    @State private var stackHeight: CGFloat = 0
    /// The part of the scroll view that shows messages, between the bars.
    @State private var visibleHeight: CGFloat = 0
    /// Scrolled up far enough that the newest line is out of sight.
    @State private var showsJump = false

    private static let conversationSpace = "conversation"
    private static let endID = "end"

    /// Empty space after the last turn, so the pinned message can sit at the
    /// top with room for the reply below it. The reply grows into it, and once
    /// the reply is longer than the screen it is gone -- the conversation then
    /// ends where the words do, and the jump button offers the rest.
    private var runway: CGFloat {
        guard pinned != nil else { return 0 }
        guard let pinnedTop else { return visibleHeight }
        return max(0, visibleHeight - (stackHeight - pinnedTop))
    }

    /// Where streamed tokens wait between draws.
    ///
    /// A class on purpose, and it is the whole point: `@State` watches the
    /// *reference*, so appending to a property inside it invalidates nothing. A
    /// `@State String` would redraw the conversation on every token, which is
    /// exactly the thing being avoided.
    @State private var stream = StreamBuffer()

    /// Twelve draws a second: fast enough to read as typing, slow enough that
    /// the view is not rebuilt on every token.
    private static let flushMilliseconds: UInt64 = 80

    /// Space between the last message and the top of the bar.
    private static let clearance: CGFloat = 20

    @MainActor
    private final class StreamBuffer {
        var pending = ""
        var isFlushScheduled = false
    }

    /// What the composer is built from. The UIKit host rebuilds its content
    /// only when this changes, not on every streamed token.
    private struct ComposerInputs: Equatable {
        var text: String
        var showsOptions: Bool
        var isWorking: Bool
        var reset: Int
        var focus: Int
        var attachments: [PendingAttachment]
    }

    private var composerInputs: ComposerInputs {
        ComposerInputs(
            text: draft, showsOptions: showsOptions,
            isWorking: isWorking, reset: composerReset, focus: composerFocus,
            attachments: pending
        )
    }

    private var showsWordmark: Bool { turns.isEmpty && draft.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(turns) { turn in
                            ChatTurnView(
                                turn: turn,
                                onAnswer: { question, value in
                                    answer(question, with: value, in: turn.id)
                                },
                                onGenerate: { choice, settings, price in
                                    generate(choice, settings: settings, price: price, in: turn.id)
                                },
                                onExport: { artifact, format in
                                    export(artifact, as: format)
                                },
                                onAnimate: { artifact in
                                    animate(artifact)
                                },
                                onApprove: { artifact in
                                    approve(artifact)
                                },
                                onRunFinished: { run in
                                    runFinished(run)
                                }
                            )
                            .id(turn.id)
                                // Fade only. A new turn sliding up while the scroll
                                // view is also animating to it, with the composer
                                // re-measuring underneath, is three animations on
                                // one send -- the message appears, gets carried
                                // off, and comes back.
                                .transition(.opacity)
                                .onGeometryChange(for: CGFloat.self) { geometry in
                                    geometry.frame(in: .named(Self.conversationSpace)).minY
                                } action: { top in
                                    if turn.id == pinned { pinnedTop = top }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .animation(.easeOut(duration: 0.18), value: turns.count)
                    .coordinateSpace(.named(Self.conversationSpace))
                    // Only while something is pinned: the lazy stack's height
                    // changes as rows are measured during any scroll, and
                    // recording it then would redraw the conversation for
                    // nothing.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if pinned != nil { stackHeight = height }
                    }

                    Color.clear
                        .frame(height: runway)
                        .allowsHitTesting(false)
                    // The very end, runway included. Scrolling "to the end" means
                    // here: the last turn's own bottom would pull a pinned message
                    // back down the screen.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.endID)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
            } action: { _, height in
                visibleHeight = max(0, height)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let end = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
                return geometry.contentOffset.y < end - 120
            } action: { _, away in
                showsJump = away
            }
            .background {
                if showsWordmark {
                    EmptyChat { suggestion in
                        draft = suggestion
                        send()
                    }
                    .padding(.bottom, barHeight + KeyboardBarController.keyboardGap)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: showsWordmark)
            // Room for the bar. The conversation runs underneath it and shows
            // through its material; this is only how far the last message
            // clears it, and it grows with the bar.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Room to breathe between the last line and the bar: the bar
                // is glass, and text running right up to its edge read as the
                // two touching.
                Color.clear
                    .frame(height: barHeight + KeyboardBarController.keyboardGap + Self.clearance)
                    .allowsHitTesting(false)
                    // Back to the newest line, from anywhere up the page.
                    .overlay(alignment: .top) {
                        if showsJump && !turns.isEmpty {
                            Button { scrollToEnd(proxy, duration: 0.35) } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(width: 38, height: 38)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .offset(y: -32)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .accessibilityLabel("Scroll to the newest message")
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: showsJump)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .onChange(of: turns.count) { old, _ in
                if scrollsToPinned, let pinned {
                    // Just sent: that message to the top, its reply to come
                    // in below it.
                    scrollsToPinned = false
                    withAnimation(.easeOut(duration: 0.35)) {
                        proxy.scrollTo(pinned, anchor: .top)
                    }
                } else {
                    // Opened: straight to the end, not an animated ride down
                    // from the first message.
                    scrollToEnd(proxy, duration: old == 0 ? nil : 0.3)
                }
            }
            .onChange(of: barHeight) { _, _ in scrollToEnd(proxy, duration: 0.18) }
            // The keyboard takes the bottom of the screen; the last message
            // should rise with it, not be left underneath it.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    scrollToEnd(proxy, duration: 0.25)
                }
            }
            .overlay {
                KeyboardAttachedBar(height: $barHeight, inputs: composerInputs) {
                    ChatComposer(
                        text: $draft,
                        showsOptions: $showsOptions,
                        isWorking: isWorking,
                        resetToken: composerReset,
                        focusToken: composerFocus,
                        attachments: pending,
                        onRemoveAttachment: { id in
                            pending.removeAll { $0.id == id }
                        },
                        onSend: { send() },
                        onStop: stop
                    )
                }
                // Full-bleed on purpose: if SwiftUI shrank this for the
                // keyboard, the bar would be back to following SwiftUI's layout
                // instead of UIKit's positioning.
                .ignoresSafeArea()
            }
        }
        .background(Theme.canvas)
        .task {
            guard let threadId, turns.isEmpty else { return }
            thread = threadId
            turns = await session.messages(in: threadId)
        }
        // No title. The page is the wordmark when empty and the conversation
        // when not; a second "Autocast" in the bar would be clutter. The way
        // back is the system back button and swipe-back, because this is
        // pushed from the Chat tab like the email app's conversation.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // Pushed page, so the tab bar slides away with the push and back with
        // the pop -- not the abrupt one-frame vanish of SwiftUI's own hiding.
        .hidesTabBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newChat()
                    } label: {
                        Label("New chat", systemImage: "plus.bubble")
                    }
                    .disabled(turns.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More options")
            }
        }
        .sheet(isPresented: $showsOptions, onDismiss: {
            if pickAfterDismiss {
                pickAfterDismiss = false
                showsPhotoPicker = true
            }
        }) {
            ChatOptionsSheet { action in
                showsOptions = false
                switch action {
                case .planMonth:
                    planning = true

                case .attachPhoto:
                    pickAfterDismiss = true

                case .ask(let text):
                    draft = text
                    // A prompt ending in a space is an invitation, not a
                    // question -- "Research " wants the rest typed, so the
                    // field is focused instead of the turn being sent.
                    if text.hasSuffix(" ") { composerFocus += 1 } else { send() }

                case .connect(let slug):
                    Task {
                        let ok = await session.connectProvider(slug)
                        if ok { say("Connected. I can see what it offers now.") }
                    }

                case .reconnect(let provider):
                    Task {
                        let ok = await session.connectProvider(provider.providerSlug)
                        if ok { say("Reconnected \(provider.providerName).") }
                    }

                case .disconnect(let provider):
                    Task {
                        await session.disconnect(provider.id)
                        say("Disconnected \(provider.providerName).")
                    }

                case .refresh(let provider):
                    Task {
                        let found = await session.refreshCapabilities(provider.id)
                        say(
                            found > 0
                                ? "\(provider.providerName) has \(found) model\(found == 1 ? "" : "s") available."
                                : "\(provider.providerName) is connected but offering nothing right now."
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $planning, onDismiss: {
            // Pushed on dismiss rather than from inside the sheet: a push that
            // races the dismissal animation is dropped, and the button then
            // looks broken to whoever pressed it.
            if proposed != nil { showingPlan = true }
        }) {
            NewPlanSheet(brief: draft) { proposed = $0 }
        }
        .navigationDestination(isPresented: $showingPlan) {
            PlanView(notice: proposed)
        }
        .photosPicker(
            isPresented: $showsPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 4,
            matching: .images
        )
        .onChange(of: photoItems) { _, items in attach(items) }
    }

    // MARK: - Attaching

    /// Uploads each picked picture as soon as it is picked, so it is there by
    /// the time somebody has finished typing what to do with it.
    private func attach(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []

        for item in items.prefix(max(0, 4 - pending.count)) {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let jpeg = Self.shrunk(image) else { return }

                let entry = PendingAttachment(
                    preview: image.preparingThumbnail(of: CGSize(width: 168, height: 168)) ?? image
                )
                pending.append(entry)

                let path = await session.uploadAttachment(jpeg)
                guard let index = pending.firstIndex(where: { $0.id == entry.id }) else { return }
                if let path {
                    pending[index].path = path
                } else {
                    // Said rather than left spinning: a thumbnail that never
                    // finishes looks like it is still coming.
                    pending.remove(at: index)
                    say("That picture didn't upload. Try it again.")
                }
            }
        }
        composerFocus += 1
    }

    /// At most 1600 pixels on the long side, as JPEG. A phone photo is twelve
    /// megapixels; the models that read it want a fraction of that, and every
    /// byte goes up on somebody's data plan.
    private static func shrunk(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 1600 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }

    // MARK: - Asking

    /// Sends what is in the composer -- with `action` when a button said
    /// exactly what it wants, so the router does not have to read it back.
    private func send(action: AppSession.ChatAction? = nil) {
        let asked = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isWorking else { return }
        // Nothing still uploading goes missing: the send button waits for
        // every picture, and a button-driven action carries none.
        guard action != nil || pending.allSatisfy({ $0.path != nil }) else { return }

        let attached = action == nil ? pending.compactMap { $0.path } : []
        if action == nil { pending = [] }

        dismissKeyboard()
        var mine = ChatMessage.user(asked)
        mine.attachments = attached
        // Only a send pins. A reopened conversation sits at the bottom.
        pinned = mine.id
        pinnedTop = nil
        scrollsToPinned = true
        turns.append(mine)
        draft = ""
        composerReset += 1

        let replyIndex = turns.count
        turns.append(.thinking)
        isWorking = true

        work = Task {
            defer {
                isWorking = false
                work = nil
                if reloadWhenIdle {
                    reloadWhenIdle = false
                    Task { await reload() }
                }
            }

            var broke = false

            do {
                try await session.streamReply(
                    for: turns, in: thread, action: action, attachments: attached
                ) { event in
                    guard turns.indices.contains(replyIndex) else { return }
                    switch event {
                    case .step(let step):
                        // The one before it is finished the moment another
                        // starts, which is what makes the ticks meaningful.
                        for index in turns[replyIndex].steps.indices {
                            turns[replyIndex].steps[index].isDone = true
                        }
                        withAnimation(.easeOut(duration: 0.18)) {
                            turns[replyIndex].steps.append(step)
                        }
                    case .delta(let text):
                        stream.pending += text
                        scheduleFlush(into: replyIndex)
                    case .models(let offer, let request, let references):
                        turns[replyIndex].offerRequest = request
                        turns[replyIndex].offerReferences = references
                        withAnimation(.easeOut(duration: 0.2)) {
                            turns[replyIndex].offer = offer
                        }
                    case .run(let id, let kind):
                        withAnimation(.easeOut(duration: 0.2)) {
                            turns[replyIndex].runId = id
                            turns[replyIndex].runKind = kind
                        }
                    case .chose(let choice):
                        turns[replyIndex].chosenModel = choice.label
                    case .thread(let id):
                        thread = id
                    case .questions(let asked, let request, let days):
                        turns[replyIndex].questionRequest = request
                        turns[replyIndex].questionDays = days
                        withAnimation(.easeOut(duration: 0.2)) {
                            turns[replyIndex].questions = asked
                        }
                    case .artifact(let id):
                        withAnimation(.easeOut(duration: 0.2)) {
                            turns[replyIndex].artifactId = id
                        }
                    case .failed(let message):
                        turns[replyIndex].isPending = false
                        turns[replyIndex].failed = true
                        turns[replyIndex].text = message
                        broke = true
                    }
                }
            } catch {
                guard turns.indices.contains(replyIndex) else { return }
                // A cancelled read is the stop button doing its job, and `stop`
                // has already tidied the turn. Checked through `Task.isCancelled`
                // as well as the error, because a cancelled `URLSession.bytes`
                // throws `URLError(.cancelled)` rather than `CancellationError`
                // -- and overwriting a half-written answer with "that did not
                // get through" is precisely what stop must not do.
                if !Task.isCancelled, !(error is CancellationError) {
                    turns[replyIndex].isPending = false
                    turns[replyIndex].failed = true
                    turns[replyIndex].text = "That did not get through. Try again."
                }
                return
            }

            if broke { return }

            flush(into: replyIndex)
            guard turns.indices.contains(replyIndex) else { return }
            turns[replyIndex].isPending = false
            for index in turns[replyIndex].steps.indices {
                turns[replyIndex].steps[index].isDone = true
            }
            // Nothing arrived but nothing failed either. Saying so is better
            // than an empty bubble somebody has to interpret.
            if turns[replyIndex].text.isEmpty {
                turns[replyIndex].failed = true
                turns[replyIndex].text = "Nothing came back. Try rephrasing."
            }
        }
    }

    /// A tapped answer, sent as though it had been typed.
    ///
    /// The card is marked answered first so it settles immediately rather than
    /// waiting for a round trip -- and it stays on screen showing what was
    /// chosen, because a conversation where the questions vanish reads as
    /// though nothing was ever agreed.
    ///
    /// Only sends once every question in that turn has an answer. Firing on the
    /// first tap would start the agent working while somebody is still deciding
    /// the second thing, which is the exact spending-before-understanding this
    /// whole flow exists to prevent.
    private func answer(_ question: ChatQuestion, with value: String, in turnID: ChatMessage.ID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        guard turns[index].answered[question.key] == nil else { return }

        turns[index].answered[question.key] = value

        let pending = turns[index].questions.filter { turns[index].answered[$0.key] == nil }
        guard pending.isEmpty else { return }

        // Said the way a person would say it, so the transcript reads as a
        // conversation rather than as a form submission.
        let said = turns[index].questions.compactMap { asked -> String? in
            guard let picked = turns[index].answered[asked.key] else { return nil }
            let label = asked.options.first { $0.value == picked }?.label ?? picked
            return "\(asked.prompt) \(label)"
        }.joined(separator: " ")

        // The sentence is for the transcript; the values travel as data, so
        // the answers are saved as what was tapped rather than re-read from
        // prose -- which is how they used to be lost.
        draft = said
        send(action: .answers(
            turns[index].answered,
            request: turns[index].questionRequest,
            days: turns[index].questionDays
        ))
    }

    /// The person approves a campaign's strategy, and the posts get written.
    ///
    /// Approval is theirs, through `approve_strategy`; the agent cannot give
    /// it. Writing the posts is the existing planner, and what it writes lands
    /// as a proposal -- nothing is scheduled until they switch the plan on.
    private func approve(_ artifact: Artifact) {
        guard let strategyID = artifact.body.strategyId, !session.isPlanning else { return }
        Task {
            guard await session.approveStrategy(strategyID) else {
                say("That approval didn't go through. Try again.")
                return
            }
            say("Approved. Writing the posts now — this takes about a minute.")

            let brief = [artifact.body.request, artifact.body.summary, artifact.body.angle]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            if let proposal = await session.proposePlan(
                brief: brief,
                days: artifact.body.days ?? 30,
                postsPerDay: artifact.body.cadence ?? 1
            ) {
                proposed = proposal
                showingPlan = true
                say("Wrote \(proposal.planned) posts. Look them over in the plan, then switch it on.")
            } else {
                say("The posts didn't get written this time. Approve again to retry — the strategy is saved.")
            }
        }
    }

    /// Generate was pressed on a card -- and only now is anything spent.
    ///
    /// The transcript still reads like the conversation ("Generate with Kling
    /// v3.0 · 720p · 5s"), but the request travels as data: the subject the
    /// offer was made for, the model's own id, the settings on the card, the
    /// price it showed, and any pictures attached to the original ask.
    ///
    /// The card settles into one line saying what was made, so reopening the
    /// thread still shows what was decided.
    private func generate(
        _ choice: ModelChoice,
        settings: GenerationSettings,
        price: ModelCost?,
        in turnID: ChatMessage.ID
    ) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        guard turns[index].chosenModel == nil, !isWorking, let offer = turns[index].offer else { return }

        var parts = [choice.label]
        if let resolution = settings.resolution {
            parts.append(resolution.hasSuffix("k") ? resolution.uppercased() : resolution)
        }
        if let quality = settings.quality { parts.append(quality.capitalized) }
        if let duration = settings.duration { parts.append("\(Int(duration.rounded()))s") }
        let summary = parts.joined(separator: " · ")
        if let price, price.amount != nil {
            turns[index].chosenModel = "\(summary) · \(price.label)"
        } else {
            turns[index].chosenModel = summary
        }

        // The request as the server recorded it; the turn before the offer for
        // offers made before the server started recording it.
        let request = turns[index].offerRequest
            ?? turns[..<index].last(where: { $0.role == .user })?.text
            ?? ""

        draft = "Generate with \(summary)"
        send(action: .generate(
            capability: offer.capability,
            prompt: request,
            model: choice.externalId,
            references: turns[index].offerReferences,
            settings: settings,
            quoted: price
        ))
    }

    /// A report as a file, from the card's Export menu.
    private func export(_ artifact: Artifact, as format: String) {
        draft = "Export as \(format == "docx" ? "Word" : format.uppercased())"
        send(action: .export(artifact: artifact.id, format: format))
    }

    /// An image made into a video, from the card's Animate button.
    private func animate(_ artifact: Artifact) {
        draft = "Animate this image"
        send(action: .animate(artifact: artifact.id))
    }

    /// A run this conversation was watching has ended. The worker wrote the
    /// result into the thread on the server, so the thread is read back rather
    /// than the result being guessed at here.
    private func runFinished(_ run: UUID) {
        guard finishedRuns.insert(run).inserted else { return }
        if isWorking {
            reloadWhenIdle = true
        } else {
            Task { await reload() }
        }
    }

    private func reload() async {
        guard let thread else { return }
        let fresh = await session.messages(in: thread)
        guard !fresh.isEmpty else { return }
        // A result arriving is the end of that exchange: the conversation
        // settles to the bottom, where the result is.
        pinned = nil
        withAnimation(.easeOut(duration: 0.2)) { turns = fresh }
    }

    /// Puts a line in the conversation from the app rather than the agent.
    ///
    /// Used for things the app did itself -- connecting a provider, asking it
    /// again what it offers. It reads as the agent speaking because from the
    /// person's side it is: they pressed something in the plus menu and this is
    /// what came back. Not persisted, because it describes an action rather
    /// than a turn, and a transcript full of "Connected." is noise on reopen.
    private func say(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            turns.append(ChatMessage(role: .assistant, text: text))
        }
    }

    private func stop() {
        work?.cancel()
        work = nil
        isWorking = false

        guard let last = turns.indices.last, turns[last].role == .assistant else { return }
        flush(into: last)
        turns[last].isPending = false
        for index in turns[last].steps.indices { turns[last].steps[index].isDone = true }
        if turns[last].text.isEmpty { turns.remove(at: last) }
    }

    private func newChat() {
        work?.cancel()
        work = nil
        isWorking = false
        stream.pending = ""
        pinned = nil
        withAnimation(.easeOut(duration: 0.2)) { turns = [] }
    }

    // MARK: - Drawing the stream

    /// Draws whatever has piled up, at most once every `flushMilliseconds`.
    private func scheduleFlush(into index: Int) {
        guard !stream.isFlushScheduled else { return }
        stream.isFlushScheduled = true

        Task {
            try? await Task.sleep(nanoseconds: Self.flushMilliseconds * 1_000_000)
            stream.isFlushScheduled = false
            flush(into: index)
        }
    }

    private func flush(into index: Int) {
        guard !stream.pending.isEmpty, turns.indices.contains(index) else { return }
        turns[index].text += stream.pending
        stream.pending = ""
    }

    // MARK: - Chrome

    /// To the very end, runway included -- so a pinned message stays where it
    /// is when the reply fits, and a long reply shows its last line. Nil
    /// duration jumps without animating.
    private func scrollToEnd(_ proxy: ScrollViewProxy, duration: Double?) {
        guard !turns.isEmpty else { return }
        // Just sent and not yet measured, the runway is a whole screen: the
        // end is past where the message should sit, and going there would
        // carry it off the top.
        guard pinned == nil || pinnedTop != nil else { return }
        if let duration {
            withAnimation(.easeOut(duration: duration)) {
                proxy.scrollTo(Self.endID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.endID, anchor: .bottom)
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}

// MARK: - The empty page

/// The name, and a few things worth asking, centred above the bar.
private struct EmptyChat: View {
    let onPick: (String) -> Void

    private static let openers = [
        "What should I post about this week?",
        "Write me three hooks for Monday",
        "What do you actually know about my brand?",
    ]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Autocast")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }

            VStack(spacing: 8) {
                ForEach(Self.openers, id: \.self) { opener in
                    Button { onPick(opener) } label: {
                        Text(opener)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background {
                                Capsule().fill(Theme.surface)
                            }
                    }
                    .buttonStyle(PressButtonStyle())
                }
            }
        }
        .padding(.horizontal, 24)
    }
}
