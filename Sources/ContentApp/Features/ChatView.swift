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
    /// Set when this screen is covering the tab bar, which is the only way it
    /// is used. Without it there would be no way out of the conversation.
    var onClose: (() -> Void)? = nil
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
    }

    private var composerInputs: ComposerInputs {
        ComposerInputs(
            text: draft, showsOptions: showsOptions,
            isWorking: isWorking, reset: composerReset, focus: composerFocus
        )
    }

    private var showsWordmark: Bool { turns.isEmpty && draft.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(turns) { turn in
                        ChatTurnView(
                            turn: turn,
                            onAnswer: { question, value in
                                answer(question, with: value, in: turn.id)
                            },
                            onChooseModel: { choice in
                                choose(choice, in: turn.id)
                            }
                        )
                        .id(turn.id)
                            // Fade only. A new turn sliding up while the scroll
                            // view is also animating to it, with the composer
                            // re-measuring underneath, is three animations on
                            // one send -- the message appears, gets carried
                            // off, and comes back.
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .animation(.easeOut(duration: 0.18), value: turns.count)
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
                Color.clear
                    .frame(height: barHeight + KeyboardBarController.keyboardGap)
                    .allowsHitTesting(false)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .onChange(of: turns.count) { _, _ in scrollToEnd(proxy, duration: 0.3) }
            .onChange(of: barHeight) { _, _ in scrollToEnd(proxy, duration: 0.18) }
            .overlay {
                KeyboardAttachedBar(height: $barHeight, inputs: composerInputs) {
                    ChatComposer(
                        text: $draft,
                        showsOptions: $showsOptions,
                        isWorking: isWorking,
                        resetToken: composerReset,
                        focusToken: composerFocus,
                        onSend: send,
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismissKeyboard()
                        onClose()
                    } label: {
                        // Down rather than back: the conversation came up over
                        // the app and this puts it away, which is what every
                        // sheet-shaped thing on the platform does.
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("Close chat")
                }
            }

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
        .sheet(isPresented: $showsOptions) {
            ChatOptionsSheet { action in
                showsOptions = false
                switch action {
                case .planMonth:
                    planning = true

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
    }

    // MARK: - Asking

    private func send() {
        let asked = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isWorking else { return }

        dismissKeyboard()
        turns.append(.user(asked))
        draft = ""
        composerReset += 1

        let replyIndex = turns.count
        turns.append(.thinking)
        isWorking = true

        work = Task {
            defer {
                isWorking = false
                work = nil
            }

            var broke = false

            do {
                try await session.streamReply(for: turns, in: thread) { event in
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
                    case .models(let offer):
                        withAnimation(.easeOut(duration: 0.2)) {
                            turns[replyIndex].offer = offer
                        }
                    case .chose(let choice):
                        turns[replyIndex].chosenModel = choice.label
                    case .thread(let id):
                        thread = id
                    case .questions(let asked):
                        withAnimation(.easeOut(duration: 0.2)) {
                            turns[replyIndex].questions = asked
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

        draft = said
        send()
    }

    /// A model was picked, or Auto was accepted.
    ///
    /// Sent back as an ordinary turn for the same reason a tapped answer is:
    /// the transcript should read like the conversation that happened, and
    /// "Use Sora 2" is what somebody would have typed.
    ///
    /// The card settles into the choice rather than disappearing, so reopening
    /// the thread still shows what was decided.
    private func choose(_ choice: ModelChoice?, in turnID: ChatMessage.ID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        guard turns[index].chosenModel == nil else { return }

        let label = choice?.label ?? turns[index].offer?.auto?.label ?? "the best available"
        turns[index].chosenModel = label

        draft = choice.map { "Use \($0.label)." } ?? "You choose."
        send()
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

    private func scrollToEnd(_ proxy: ScrollViewProxy, duration: Double) {
        guard let last = turns.last else { return }
        withAnimation(.easeOut(duration: duration)) {
            proxy.scrollTo(last.id, anchor: .bottom)
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
