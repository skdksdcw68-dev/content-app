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
    /// A request made somewhere else -- typed into Create -- sent as the first
    /// turn of a new conversation, so starting a job and talking about it are
    /// the same place rather than two.
    var opening: String? = nil
    /// Opened from Home's "Describe a video to make" field. Same conversation,
    /// same agent, same artifacts -- but the field asks for a video and the
    /// strip above it carries the video's own choices (Abel, 24 Sep 2026:
    /// "similar as the chat but different text input video, which included
    /// video things instead of a text").
    var makingVideo = false
    /// A saved generation, reopened from a list that already knows what it
    /// is. The generator is drawn from the first frame instead of after a
    /// read, so the bar never starts as plain chat and then changes.
    var opensAsGeneration = false

    @Environment(AppSession.self) private var session

    @State private var turns: [ChatMessage] = []
    /// Reading a saved conversation back. Without this the empty-state
    /// wordmark flashes over a thread that is about to appear.
    @State private var restoring = false
    @State private var draft = ""
    @State private var isWorking = false
    @State private var showsOptions = false
    /// The video page's choices.
    /// What the composer is set to make. One value instead of three loose
    /// flags, because the bar, the settings sheet and the model picker all
    /// read and write the same choices.
    @State private var choices = GenerateChoices()
    /// Chat wearing the generator as a tag: Video or Image chosen from the
    /// plus sheet. Nil is plain chat. The dedicated page sets makingVideo
    /// instead; isGenerating is the one question everything else asks.
    @State private var creating: GenerateChoices.Mode?
    /// A generation thread reopened from the chats list, where the route
    /// cannot say so. Read off the thread itself on restore.
    @State private var reopenedGeneration = false
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
    /// Which pill opened the picker, so one picture lands where it was asked
    /// for rather than in the general pile.
    @State private var fillingSlot: GenerateAttachments.Slot = .reference
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

    private var showsWordmark: Bool { turns.isEmpty && draft.isEmpty && !restoring }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // 🔴 Two different pages share this scroll view now. Chat
                    // keeps its bubbles; the generator draws the ElevenLabs
                    // feed -- kind, prompt, result, newest on top, no
                    // narration (Abel, 26 Sep 2026: "yes i said.").
                    if (makingVideo || reopenedGeneration || opensAsGeneration) && !turns.isEmpty {
                        GenerationFeed(
                            turns: turns,
                            onCopy: { prompt in
                                draft = prompt
                                composerFocus += 1
                            },
                            onRetry: { prompt in
                                draft = prompt
                                send()
                            },
                            onAnimate: { artifact in animate(artifact) },
                            onReference: { artifact in useAsReference(artifact) }
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                        .animation(.easeOut(duration: 0.18), value: turns.count)
                    } else {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(turns) { turn in
                            turnView(turn)
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
                if restoring {
                    VStack(alignment: .leading, spacing: 14) {
                        SkeletonBubble()
                        SkeletonBubble().opacity(0.7)
                        SkeletonBubble().opacity(0.45)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .transition(.opacity)
                } else if showsWordmark {
                    // 🔴 One greeting, both pages. Abel, 26 Sep 2026: "why
                    // does the clean page have that one 3 question ideas +
                    // make a video thing?? i want it to be very clean as the
                    // normal chat."
                    //
                    // Yesterday the video page got a heading, a subtitle and
                    // three tappable starters, on the grounds that a bare
                    // greeting told nobody what to write. It told them at the
                    // cost of a screenful of furniture, on a page whose only
                    // job is to hold one sentence somebody is about to type.
                    // The composer already says "What's the video about?"
                    // an inch below, which was always the better place for it.
                    EmptyChat(name: session.displayName ?? session.brand?.name)
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
            // Dragging closes the keyboard. The tap that used to do it lived
            // on this ScrollView as a `simultaneousGesture` and could take a
            // touch meant for a bubble, a link or a button inside it; the
            // screen's background does the same job from behind, where it
            // cannot. See `KeyboardDismiss`.
            .scrollDismissesKeyboard(.interactively)
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
                        // Abel, 25 Sep 2026: "keep the page very clean sir
                        // please like whats the video about or something."
                        placeholder: isGenerating ? (choices.mode == .image ? "What's the image about?" : "What's the video about?") : "Ask Autocast",
                        accessory: isGenerating ? AnyView(videoAttachments) : nil,
                        footer: isGenerating ? AnyView(videoControls) : nil,
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
        .background(Theme.canvas.dismissesKeyboardOnTap().ignoresSafeArea())
        .task {
            guard let threadId, turns.isEmpty else { return }
            thread = threadId
            restoring = true
            // What this thread IS comes back with it. The route that opened
            // it says nothing: from the chats list every thread arrives as
            // `.chat(id)`, and a generation reopened that way was losing its
            // feed, its bar and its send button's whole meaning.
            // (Already known when the list opened it as a generation; asked
            // of the thread itself only when it came in by any other road.)
            var isGeneration = opensAsGeneration
            if !isGeneration {
                isGeneration = await session.threadKind(threadId) == "generation"
            }
            if isGeneration {
                reopenedGeneration = true
                choices.mode = .video
                if choices.model == nil {
                    let models = await session.models(capability: choices.mode.capability, withPicture: false)
                    choices.model = models.first(where: \.recommended) ?? models.first
                }
            }
            turns = await session.messages(in: threadId)
            restoring = false
        }
        .task {
            // Asked for on the way in. Sent as though it had been typed, so the
            // transcript reads the way the conversation went.
            guard let opening, threadId == nil, turns.isEmpty, draft.isEmpty else { return }
            // Opened with nothing to say -- Home's field is a door now, not a
            // place to type (Abel, 25 Sep 2026: "when they click I want it to
            // exactly redirect them to the next page"). So put the cursor in
            // the composer and wait, rather than sending an empty turn.
            guard !opening.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                composerFocus += 1
                return
            }
            draft = opening
            send()
        }
        .task {
            guard makingVideo else { return }
            await session.refreshInspiration()
            // A model from the first moment, so the send button is always a
            // generate button and nobody is ever offered a card asking them
            // to choose what the bar already shows. ElevenLabs opens with one
            // selected for the same reason. The recommendation is the
            // server's; the person changes it on the ✦ knob.
            if choices.model == nil {
                let models = await session.models(capability: choices.mode.capability, withPicture: false)
                choices.model = models.first(where: \.recommended) ?? models.first
            }
            // A picture chosen in the Library on the way here: set up in the
            // composer now that a model is chosen for it to be checked against.
            if let handoff = session.takeReferenceHandoff() {
                await use(handoff.artifact, animating: handoff.animating)
            }
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
            // The shelf of everything made, one tap from where it is made
            // (Abel, 29 Sep 2026: no "Library" anywhere on the generator).
            if isGenerating {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.push(.generated)
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .accessibilityLabel("Library")
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
        .sheet(isPresented: $showsOptions, onDismiss: {
            if pickAfterDismiss {
                pickAfterDismiss = false
                showsPhotoPicker = true
            }
        }) {
            // 🔴 The sheet has taken a `makingVideo` flag all along and nobody
            // ever passed it, so the video page's plus button opened the full
            // chat menu -- "Plan 30 days", "Look into something" -- on a
            // screen whose only job is one video.
            ChatOptionsSheet(makingVideo: makingVideo) { action in
                showsOptions = false
                switch action {
                case .create(let mode):
                    // A tag, not text. The composer flips into the generator
                    // -- pills above, the bar below, send submits the job --
                    // and the × on the tag flips it back to plain chat.
                    creating = mode
                    choices.mode = mode
                    choices.model = nil
                    composerFocus += 1
                    Task {
                        let models = await session.models(capability: mode.capability, withPicture: false)
                        if choices.model == nil {
                            choices.model = models.first(where: \.recommended) ?? models.first
                        }
                    }

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
        // 🔴 One picture for a frame slot, up to four otherwise. Abel, 26 Sep
        // 2026: "while uploaded end and start frame, our accepts whatever
        // amount 😂😂😂 bit see the elevven labs when uploaded."
        //
        // All three pills opened this one picker at four apiece, so "Start
        // frame" could take four pictures and none of them was the start
        // frame in particular -- they all landed in the same list and the
        // model got whichever came first. A frame is a slot with one thing in
        // it, and `fillingSlot` says which slot is being filled.
        .photosPicker(
            isPresented: $showsPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: fillingSlot == .reference ? 4 : 1,
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

        // A frame slot takes exactly one, and picking again replaces what was
        // there rather than adding to a pile.
        if fillingSlot != .reference, let item = items.first {
            let slot = fillingSlot
            fillingSlot = .reference
            Task { await fill(slot, from: item) }
            return
        }

        for item in items.prefix(max(0, 4 - pending.count)) {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let picked = UIImage(data: data) else { return }

                // 🔴 On the video page the picture decides the shape of the
                // video, so it has to be the shape of the video.
                //
                // A picture attached to a video request routes to fal's
                // image-to-video endpoint, which has no aspect ratio field at
                // all -- the output takes the picture's shape. Abel's first
                // real video came back 1328x694 from a landscape photo, and
                // nothing in the composer could have changed that.
                let image = isGenerating ? VerticalFit.padded(picked) : picked
                guard let jpeg = Self.shrunk(image) else { return }

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

    /// One turn, with everything it can do wired up. Its own function because
    /// the whole call inline in the list was too much for the type checker.
    private func turnView(_ turn: ChatMessage) -> ChatTurnView {
        let id = turn.id
        var retry: (() -> Void)? = nil
        if canRegenerate(id) {
            retry = { regenerate(id) }
        }
        return ChatTurnView(
            turn: turn,
            onAnswer: { question, value in
                answer(question, with: value, in: id)
            },
            onGenerate: { choice, settings, price in
                generate(choice, settings: settings, price: price, in: id)
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
            onReference: { artifact in
                useAsReference(artifact)
            },
            onRunFinished: { run in
                runFinished(run)
            },
            onSuggest: { suggestion in
                // One ending in a space wants the rest typed -- "Edit it: " --
                // so the field is focused instead of the turn being sent.
                draft = suggestion
                if suggestion.hasSuffix(" ") { composerFocus += 1 } else { send() }
            },
            onRate: { rating, reason in
                rate(id, rating: rating, reason: reason)
            },
            onRegenerate: retry,
            showsActionsTip: id == firstAnswerId
        )
    }

    // MARK: - Rating and retrying

    /// The first finished answer, which carries the one-time tip.
    private var firstAnswerId: UUID? {
        turns.first { $0.role == .assistant && !$0.isPending && !$0.failed && !$0.text.isEmpty }?.id
    }

    /// Only the latest answer, to a plain text question, while nothing is
    /// running: re-asking an earlier one would rewrite the conversation, and a
    /// question that came with pictures cannot be re-sent without them.
    private func canRegenerate(_ id: UUID) -> Bool {
        guard !isWorking,
              let index = turns.firstIndex(where: { $0.id == id }),
              index == turns.count - 1,
              index > 0,
              turns[index - 1].role == .user,
              turns[index - 1].attachments.isEmpty,
              !turns[index - 1].text.isEmpty
        else { return false }
        return true
    }

    private func rate(_ id: UUID, rating: String, reason: String?) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        // Tapping the same thumb again takes it back, locally.
        if turns[index].rating == rating && reason == nil {
            turns[index].rating = nil
            return
        }
        turns[index].rating = rating
        let reply = turns[index].text
        let asked = index > 0 && turns[index - 1].role == .user ? turns[index - 1].text : nil
        let conversation = thread
        Task {
            await session.rateReply(thread: conversation, asked: asked, reply: reply, rating: rating, reason: reason)
        }
    }

    /// Asks the same question again for a different answer.
    private func regenerate(_ id: UUID) {
        guard canRegenerate(id), let index = turns.firstIndex(where: { $0.id == id }) else { return }
        let asked = turns[index - 1].text
        if turns[index].rating == nil {
            let reply = turns[index].text
            let conversation = thread
            Task {
                await session.rateReply(thread: conversation, asked: asked, reply: reply, rating: "down", reason: "Asked for another answer")
            }
        }
        withAnimation(.easeOut(duration: 0.18)) {
            turns.removeSubrange((index - 1)...index)
        }
        draft = asked
        send()
    }

    // MARK: - Asking

    /// Sends what is in the composer -- with `action` when a button said
    /// exactly what it wants, so the router does not have to read it back.
    /// Stores a pasted key and says so, in the conversation, masked.
    ///
    /// Both turns are local. Nothing about a key is written to the thread on
    /// the server -- the whole point is that it exists in one sealed place and
    /// nowhere else.
    private func saveKey(_ key: PastedKey) {
        turns.append(.user("\(key.preamble.isEmpty ? "" : key.preamble + "\n")\(key.maskedSecret)"))
        let replyIndex = turns.count
        turns.append(.thinking)
        isWorking = true

        Task {
            defer { isWorking = false }
            let ok = await session.connectGenerator(keyID: key.id, keySecret: key.secret)
            guard replyIndex < turns.count else { return }
            turns[replyIndex] = ChatMessage(
                role: .assistant,
                text: ok
                ? "Saved. That key is encrypted and I can't read it back — you'll only ever see \(key.maskedSecret). I'll use it to make your videos. Ask me for one whenever you like."
                : "That key didn't work when I tried it against the provider. Nothing was saved. Check it was copied whole, and that it's the pair — the id and the secret, not just one of them."
            )
        }
    }

    /// The video's own choices, under the field: the six knobs that change
    /// what comes back, in ElevenLabs' order, with everything else behind the
    /// sliders icon. See `GenerateBar`.
    ///
    /// 🔴 What was here: a stepper and two chips -- length, Voiceover,
    /// Captions -- and no way at all to choose the model, the count or the
    /// aspect ratio, in an app whose whole job is making video. The length
    /// stepper was right and is kept, in the clock knob and in the settings
    /// sheet, where any second from 5 to 180 is still reachable.
    ///
    /// Abel, 25 Sep 2026, with fifteen screenshots: "i want it to match the
    /// exact eleven labs thing, that makes more sense and looks so good."
    private var isGenerating: Bool { makingVideo || reopenedGeneration || opensAsGeneration || creating != nil }

    private var videoControls: some View {
        GenerateBar(choices: $choices, request: draft)
    }

    /// What you are giving it, above the field: a picture to work from, and
    /// the first and last frame when the chosen model takes them.
    private var videoAttachments: some View {
        GenerateAttachments(
            choices: $choices,
            tag: creating.map { $0 == .image ? "Image" : "Video" },
            onClearTag: { creating = nil }
        ) { slot in
            // Which slot is being filled decides how many pictures the picker
            // will take, and where the one that comes back is put.
            fillingSlot = slot
            showsPhotoPicker = true
        }
    }

    /// One picture into a frame slot: shrunk, made vertical, uploaded, and
    /// shown on its own pill.
    private func fill(_ slot: GenerateAttachments.Slot, from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let picked = UIImage(data: data) else { return }
        let image = VerticalFit.padded(picked)
        guard let jpeg = Self.shrunk(image) else { return }
        guard let path = await session.uploadAttachment(jpeg) else {
            say("That picture didn't upload. Try it again.")
            return
        }
        let pick = GenerateChoices.FramePick(path: path, preview: image)
        switch slot {
        case .start: choices.startFrame = pick
        case .end:   choices.endFrame = pick
        case .reference: break
        }
    }

    private func send(action: AppSession.ChatAction? = nil) {
        var asked = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        // A provider key pasted into the field never becomes a message. It is
        // taken here, verified and sealed by the server, and only its masked
        // form is shown -- so it never reaches the model and never sits in a
        // transcript (Abel, 24 Sep 2026).
        if action == nil, let key = PastedKey.find(in: asked) {
            draft = ""
            composerReset += 1
            saveKey(key)
            return
        }

        // 🔴 On the video page, SEND IS GENERATE.
        //
        // Abel, 26 Sep 2026: "if the user already chooses a model why does
        // they need to be asked for?? justmake it as elevenlabs." And he had
        // been through it: he named Wan 2.5 in the composer, the agent
        // replied "Pick a model and quality, then tap Generate", and he had
        // to say everything a second time on a card.
        //
        // The composer already knows the model, the length, the resolution,
        // the sound, the frames and the count. Sending all of that to a
        // writer so it can offer it back as a card is a conversation about a
        // decision that has been made. So the send button submits the job
        // itself -- the same `.generate` action the card's button sent --
        // and the reply is the result, counting up, like the screenshots.
        //
        // Except for "Hi". A greeting is not a subject (`SmallTalk`): it goes
        // to the agent, which asks what the video should be of, and the next
        // message -- the actual idea -- is the one that is made.
        if isGenerating, action == nil, let model = choices.model, !asked.isEmpty, !SmallTalk.matches(asked) {
            // Frames first and in order: an adapter reads the first
            // reference as the start frame and the second as the end.
            guard pending.allSatisfy({ $0.path != nil }) else { return }
            let references = choices.frames + pending.compactMap { $0.path }
            pending = []
            choices.startFrame = nil
            choices.endFrame = nil
            send(action: .generate(
                capability: choices.mode.capability,
                prompt: asked,
                model: model.externalId,
                references: references,
                settings: choices.settings,
                quoted: nil
            ))
            return
        }

        // The video page's choices travel with the request -- the path for
        // when no model is chosen yet and the router should pick.
        if makingVideo, action == nil, !asked.isEmpty { asked += "\n\(choices.spec)" }
        // A photo on its own is a message: it says "here, do something with
        // this", and the agent answers with what it could do.
        let photosOnly = asked.isEmpty && action == nil && !pending.isEmpty
        guard !asked.isEmpty || photosOnly, !isWorking else { return }
        // Nothing still uploading goes missing: the send button waits for
        // every picture, and a button-driven action carries none.
        guard action != nil || pending.allSatisfy({ $0.path != nil }) else { return }

        // The frames go FIRST and in order, because an adapter reads the
        // first reference as the start frame and the second as the end. A
        // general picture attached alongside follows them.
        let attached = action == nil ? choices.frames + pending.compactMap { $0.path } : []
        if action == nil {
            pending = []
            choices.startFrame = nil
            choices.endFrame = nil
        }

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
                        // A thread born on the generator is marked as one, so
                        // reopening it from the list comes back as the
                        // generator and not as plain chat (Abel, 26 Sep 2026).
                        if isGenerating {
                            Task { await session.markThreadGeneration(id) }
                        }
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
                    case .suggestions(let options):
                        withAnimation(.easeOut(duration: 0.2)) {
                            turns[replyIndex].suggestions = options
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
        // Whatever else the model asked for -- the voice it will speak in.
        parts.append(contentsOf: settings.extras.values.sorted())
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
    ///
    /// On the generator the picture goes INTO the composer -- as the start
    /// frame, or the reference for a model that takes only one -- and what is
    /// typed next is the motion. Send is generate there, so nothing else has to
    /// happen. This used to send "Animate this image" as a chat message and
    /// wait for the agent to answer with a card asking which model, on a page
    /// whose model was already chosen; and from the feed it did not run at all.
    /// Plain chat keeps its own path, where the agent offers the models.
    private func animate(_ artifact: Artifact) {
        if isGenerating {
            Task { await use(artifact, animating: true) }
            return
        }
        draft = "Animate this image"
        send(action: .animate(artifact: artifact.id))
    }

    /// A picture that was made, put in the composer as a reference for the
    /// next request: the pill shows it, the send button carries it, and the
    /// model is told what it is.
    private func useAsReference(_ artifact: Artifact) {
        Task { await use(artifact, animating: false) }
    }

    /// Takes a made picture into the composer the way a photo from the camera
    /// roll is taken -- shrunk, made vertical on the generator, uploaded -- so
    /// everything already built for an attached picture (the pill, the price,
    /// the request) treats it as one. Nothing about it is special-cased.
    ///
    /// Abel, 29 Sep 2026: "when you are trying to use an image for a video
    /// preference or something, or an image preference, it's not going to
    /// attach it, and it's not going to use it. The AI won't understand what
    /// it has to do." A made picture lives in the server's artifacts, and
    /// chat only accepts uploads it was handed from the phone -- so there was
    /// no way to attach one at all. Reading it back through the phone and
    /// uploading it again is the one path every layer already trusts.
    private func use(_ artifact: Artifact, animating: Bool) async {
        guard let picked = await session.picture(of: artifact, longest: 1600) else {
            say("I couldn't open that picture. Try again.")
            return
        }

        // Animating means a video model, and one that will take a picture.
        if animating, isGenerating, choices.mode != .video {
            choices.mode = .video
            choices.model = nil
            if creating != nil { creating = .video }
        }
        if isGenerating {
            let capable = await session.models(capability: choices.mode.capability, withPicture: true)
            let current = choices.model
            if current == nil || !capable.contains(where: { $0.externalId == current?.externalId }) {
                choices.model = capable.first(where: \.recommended) ?? capable.first ?? current
            }
        }

        let image = isGenerating ? VerticalFit.padded(picked) : picked
        guard let jpeg = Self.shrunk(image), let path = await session.uploadAttachment(jpeg) else {
            say("That picture didn't upload. Try it again.")
            return
        }

        if animating, isGenerating, BuiltInModels.takesFrames(choices.model) {
            choices.startFrame = GenerateChoices.FramePick(path: path, preview: image)
        } else if pending.count < 4 {
            pending.append(PendingAttachment(
                preview: image.preparingThumbnail(of: CGSize(width: 168, height: 168)) ?? image,
                path: path
            ))
        }
        composerFocus += 1
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
    /// What to call them: the name they gave, else the brand, else nothing.
    let name: String?

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let time: String
        switch hour {
        case 5..<12:  time = "Good morning"
        case 12..<18: time = "Good afternoon"
        default:      time = "Good evening"
        }
        let first = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
        if let first, !first.isEmpty { return "\(time), \(first)" }
        return time
    }

    // One line, in the middle, nothing else (Abel, 22 Sep 2026: "on a new
    // chat why do we need so much thing?? only a clean (name), Good morning").
    var body: some View {
        Text(greeting)
            .font(.title2.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
