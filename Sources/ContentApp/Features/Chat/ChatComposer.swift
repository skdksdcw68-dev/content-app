import SwiftUI
import UIKit
import UIKit

/// The chat input, in ChatGPT's shape and with ChatGPT's motion.
///
/// A single-row capsule, 48pt at rest: plus on the left, the field in the
/// middle, send on the right, all on one line. It never becomes a panel. Focus
/// widens it from 34pt side margins to 12pt, in step with the keyboard rising;
/// a new line grows it upward with the buttons pinned to the bottom edge.
///
/// While the agent is answering, the send button becomes a stop button. That is
/// how the platform's assistants show work in progress: not a placeholder that
/// says "typing", but a control that lets you end it.
///
/// Positioning is not this view's job. `KeyboardAttachedBar` pins it to the
/// keyboard through UIKit; nothing here animates position.
struct ChatComposer: View {
    @Binding var text: String
    @Binding var showsOptions: Bool
    let isWorking: Bool
    /// Bumped by the owner after a send. The field is rebuilt under a new
    /// identity, which is the one reliable way to make a vertical TextField
    /// drop back to one line -- clearing its text while it was three lines tall
    /// left it three lines tall, with the placeholder sitting in the space the
    /// question used to take.
    let resetToken: Int
    /// Bumped by the owner to put the cursor in the field. Focus has to live on
    /// this side of the UIKit hosting boundary, so it is asked for rather than
    /// set from outside.
    let focusToken: Int
    /// Pictures waiting to go with the next message. Drawn from the local
    /// image, not fetched: this view is hosted by UIKit outside the SwiftUI
    /// environment, and a thumbnail should not wait on a network round trip.
    var attachments: [PendingAttachment] = []
    /// What the empty field says. The video page asks for a video, not a
    /// question (Abel, 24 Sep 2026).
    var placeholder = "Ask Postpilot"
    /// A strip above the field. The video page puts its attachment pills here
    /// -- "Image", "Start frame", "End frame". Nothing is drawn when nil.
    var accessory: AnyView?
    /// A strip BELOW the field, sharing its row with Send. The video page puts
    /// the six generate controls here, which is where ElevenLabs keeps them
    /// and why their composer reads top to bottom: what you are giving it,
    /// what you are asking for, how it should come back.
    ///
    /// When this is set the plus button goes: its job -- attaching a picture
    /// -- has moved to a named pill above, where somebody can tell what it
    /// does without tapping it.
    var footer: AnyView?
    var onRemoveAttachment: (UUID) -> Void = { _ in }
    /// Videos waiting to go: their sound is being, or has been, turned into
    /// words, and the words travel with the message.
    var videos: [PendingVideo] = []
    var onRemoveVideo: (UUID) -> Void = { _ in }
    /// A voice note was recorded: the owner turns it into words and puts them
    /// in the field. Nil hides the microphone (the generator's bar has none).
    var onVoice: ((URL) async -> Void)?
    /// A Create video button beside the plus (Netro, 19 Oct 2026). Nil on the
    /// video page itself, where the whole screen already is that.
    var onCreateVideo: (() -> Void)?
    /// The generator's settings -- model, how many, shape, quality, length --
    /// behind a sliders button in the bar, the way Grok keeps them (Abel,
    /// 1 Nov 2026). Nil hides it.
    var onSettings: (() -> Void)?
    let onSend: () -> Void
    let onStop: () -> Void
    /// The plan, for the model picker: Opus is Max and Ultra (0 free, 1 Pro,
    /// 2 Max, 3 Ultra). Passed in because this bar lives outside the environment.
    var planRank: Int = 0

    @FocusState private var isFocused: Bool
    /// Fast, Normal or Deep. Kept on the phone and read by the request that
    /// sends the message.
    @State private var models = ChatModelPrefs.current
    /// The bar grown to full screen for a long message (Abel, 7 Nov 2026). The
    /// same bar, not a new page, so the words, the cursor and the keyboard stay.
    @State private var isFull = false
    @State private var fieldHeight: CGFloat = 0
    @State private var barHeight: CGFloat = 0
    @Environment(BarRoom.self) private var room: BarRoom?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Lives on this side of the hosting boundary, like focus: a recording is
    /// the bar's own business until it has words to hand over.
    @State private var recorder = VoiceRecorder()
    @State private var transcribing = false
    @State private var micRefused = false

    private var hasRequest: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The microphone takes the send button's place while there is nothing to
    /// send, the way every assistant's bar does.
    private var showsMic: Bool {
        onVoice != nil && footer == nil && !hasRequest && attachments.isEmpty && videos.isEmpty && !isWorking
    }

    /// A picture on its own is a message -- "here, do something with this" --
    /// so it sends with nothing typed. Never while one is still uploading:
    /// sending then would send the message without it, and the person would
    /// think it had been seen.
    private var canSend: Bool {
        (hasRequest || !attachments.isEmpty || !videos.isEmpty) && !isWorking && !transcribing
            && attachments.allSatisfy { $0.path != nil }
            && videos.allSatisfy { $0.transcript != nil }
    }

    /// Wide as soon as the field is focused, not only once there is text.
    /// Measured off ChatGPT: it widens *during* the keyboard's rise, so the two
    /// read as one gesture; waiting for the first character made ours a
    /// separate, later event.
    private var isExpanded: Bool { isFocused || hasRequest }

    var body: some View {
        capsule
            // 34 at rest left roughly 160pt to type in on a 390pt screen, once
            // the plus and the send button had taken their 32 each (Abel,
            // 25 Sep 2026: "the text input is so much narrow and it looks so
            // much annoying"). 20 keeps the capsule floating rather than
            // edge-to-edge, and gives back 28pt of words.
            // Narrower at rest when the Create video pill shares the row, so the
            // field keeps room for its words on one line (Netro, 19 Oct 2026:
            // the pill and the text sat on separate lines).
            .padding(.horizontal, isExpanded ? 10 : (onCreateVideo != nil && footer == nil ? 14 : 20))
            .padding(.top, 6)
            .animation(.easeOut(duration: 0.22), value: isExpanded)
            .sensoryFeedback(.impact(weight: .light), trigger: showsOptions)
            .sensoryFeedback(.impact(weight: .medium), trigger: isWorking)
            .onChange(of: focusToken) { _, _ in isFocused = true }
            .onChange(of: resetToken) { _, _ in isFull = false }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
    }

    private var capsule: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let accessory { accessory }
            if !attachments.isEmpty || !videos.isEmpty {
                pendingStrip
            }

            if recorder.isRecording {
                recordingCard
            } else if isPlainBar {
                plainRow
            } else {
                HStack(alignment: .bottom, spacing: onCreateVideo != nil && footer == nil ? 4 : 6) {
                    if footer == nil { plusButton }
                    if footer == nil, onCreateVideo != nil { createVideoButton }
                    field
                    if footer == nil, onSettings != nil { settingsButton }
                    if showsMic { micButton } else if footer == nil { actionButton }
                }
            }

            if let footer {
                HStack(alignment: .center, spacing: 6) {
                    footer
                    Spacer(minLength: 0)
                    actionButton
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        // The system's own Liquid Glass, interactive: it catches the light and
        // gives under a touch the same way the tab bar and toolbar buttons do.
        // A material with a hairline border was a drawing of a native control;
        // this is the control's material itself, so it moves like the rest of
        // iOS 26 without any animation of ours.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        .animation(.easeOut(duration: 0.15), value: isFocused)
        // A new line grows the capsule smoothly instead of snapping it a line
        // taller. Keyed to the text because that is the only thing that changes
        // the line count; on an ordinary keystroke nothing moves.
        .animation(.easeOut(duration: 0.18), value: text)
    }

    private var pendingStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    Image(uiImage: attachment.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            if attachment.path == nil {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.black.opacity(0.35))
                                    .overlay { ProgressView().tint(.white) }
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Button { onRemoveAttachment(attachment.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .font(.system(size: 18))
                            }
                            .offset(x: 5, y: -5)
                            .accessibilityLabel("Remove picture")
                        }
                }
                ForEach(videos) { video in
                    ZStack {
                        if let poster = video.poster {
                            Image(uiImage: poster).resizable().scaledToFill()
                        } else {
                            Color.primary.opacity(0.12)
                        }
                        Color.black.opacity(video.transcript == nil ? 0.45 : 0.25)
                        if video.transcript == nil {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "text.bubble.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Text(String(format: "%d:%02d", video.seconds / 60, video.seconds % 60))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 3)
                    }
                    .overlay(alignment: .topTrailing) {
                        Button { onRemoveVideo(video.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .font(.system(size: 18))
                        }
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove video")
                    }
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 6)
        }
    }

    private var plusButton: some View {
        Button {
            isFocused = false
            showsOptions = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .accessibilityLabel("Options")
    }

    /// Make a video from here. With words typed it makes them; with none it
    /// opens the video controls. Labelled while the field is at rest, and just
    /// the icon once somebody is typing, so the field keeps its width.
    private var createVideoButton: some View {
        Button {
            isFocused = false
            onCreateVideo?()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "video.fill")
                    .font(.system(size: 13, weight: .semibold))
                if !isExpanded {
                    Text("Create video")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, isExpanded ? 0 : 9)
            .frame(minWidth: 32, minHeight: 32)
            .background(Theme.accent, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressButtonStyle())
        .disabled(isWorking)
        .animation(.easeOut(duration: 0.2), value: isExpanded)
        .accessibilityLabel("Create video")
    }

    private var settingsButton: some View {
        Button {
            isFocused = false
            onSettings?()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .accessibilityLabel("Picture and video settings")
    }

    /// Tap to start a voice note.
    private var micButton: some View {
        Button {
            isFocused = false
            Task {
                if await recorder.start() == false { micRefused = true }
            }
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .disabled(transcribing)
        .accessibilityLabel("Record a voice note")
        .alert("Microphone is off", isPresented: $micRefused) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn it on for Postpilot in Settings > Privacy > Microphone, then try again.")
        }
    }

    /// What has been said so far, after anything already typed.
    private var dictated: String {
        [text, recorder.liveText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// While talking (Claude's way): your words above, and under them an X to
    /// throw it away, the waveform, the time, and a check to keep it. The check
    /// is not Send: it only puts the words in the field.
    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dictated.isEmpty ? "Listening…" : dictated)
                .font(.system(size: 16))
                .lineSpacing(3)
                .foregroundStyle(dictated.isEmpty ? .secondary : .primary)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack(spacing: 10) {
                Button { recorder.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(PressButtonStyle())
                .accessibilityLabel("Discard recording")

                // Your voice as you speak, scrolling in from the right.
                RecordingWave(levels: recorder.levels)
                    .frame(maxWidth: .infinity)

                Text(recorder.clock)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    Task { await finishTalking() }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.blue))
                }
                .buttonStyle(PressButtonStyle())
                .accessibilityLabel("Finish talking")
            }
        }
    }

    /// The check: the words go into the field at once and the cursor lands after
    /// them. Only when the phone could not listen does the sound go to the
    /// server, as it always used to.
    private func finishTalking() async {
        let heard = await recorder.finish()
        if !heard.words.isEmpty {
            text = text.isEmpty ? heard.words : text + " " + heard.words
            isFocused = true
        } else if let file = heard.file {
            transcribing = true
            await onVoice?(file)
            try? FileManager.default.removeItem(at: file)
            transcribing = false
        }
    }

    /// The message field. Its own property so the bar's body stays small enough
    /// for the compiler.
    private var field: some View {
        TextField(
            transcribing ? "Writing it down…" : (attachments.isEmpty && videos.isEmpty ? placeholder : "Say what to do with it"),
            text: $text,
            axis: .vertical
        )
            .font(.system(size: 16))
            .lineSpacing(3)
            // One line at rest, growing to ten (six on the generator's bar),
            // then scrolling inside itself. Full screen holds it at the lines
            // that fit. The buttons stay on the bottom edge while it grows.
            .lineLimit(isFull ? fullLines...fullLines : 1...(isPlainBar ? 10 : 6))
            // The placeholder stays on one line; it used to wrap to
            // two when the row was tight.
            .minimumScaleFactor(0.85)
            .focused($isFocused)
            .padding(.horizontal, footer == nil ? 4 : 8)
            .padding(.vertical, 7)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
            .id(resetToken)
    }

    /// One line of the field: 16 pt text plus its 3 pt line spacing.
    private static let lineHeight = UIFont.systemFont(ofSize: 16).lineHeight + 3

    /// The expand button shows once the words reach ten lines, and stays while
    /// the bar is full screen so it can shrink it back.
    private var showsExpand: Bool {
        isPlainBar && room != nil && (isFull || fieldHeight - 14 >= Self.lineHeight * 9.5)
    }

    /// How many lines fill the screen: the room above the keyboard, less the
    /// rest of the bar (buttons, padding).
    private var fullLines: Int {
        let chrome = max(0, barHeight - fieldHeight)
        let lines = Int(((room?.available ?? 0) - chrome - 14) / Self.lineHeight)
        return max(10, lines)
    }

    private var expandButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { isFull.toggle() }
        } label: {
            Image(systemName: isFull ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(PressButtonStyle())
        .transition(.opacity)
        .accessibilityLabel(isFull ? "Shrink" : "Full screen")
    }

    /// The ordinary chat bar: no generator strip, no sliders, no video pill.
    private var isPlainBar: Bool {
        footer == nil && onSettings == nil && onCreateVideo == nil
    }

    /// Claude's bar (Abel, 5 Nov 2026, approving the mockup): the words on top,
    /// growing a line at a time as they need room, and under them the plus, the
    /// model chip, the microphone and Send. The field never moves in the tree,
    /// so focus and the cursor stay put while it grows.
    private var plainRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            field
                .padding(.trailing, showsExpand ? 30 : 0)
                .overlay(alignment: .topTrailing) {
                    if showsExpand { expandButton }
                }
                .animation(.easeOut(duration: 0.18), value: showsExpand)
            HStack(spacing: 8) {
                plusButton
                EffortMenu(prefs: $models)
                Spacer(minLength: 0)
                if canDictate { micButton }
                actionButton
            }
        }
        .onChange(of: models) { _, now in ChatModelPrefs.current = now }
    }

    /// The microphone is offered whenever there is a place to put the words.
    private var canDictate: Bool {
        onVoice != nil && !isWorking
    }

    /// Send, or -- while an answer is being written -- stop.
    private var actionButton: some View {
        Button {
            if isWorking { onStop() } else { onSend() }
        } label: {
            Image(systemName: isWorking ? "stop.fill" : "arrow.up")
                .font(.system(size: isWorking ? 13 : 17, weight: .semibold))
                // NOT .white. Theme.accent is near-black in light mode and
                // near-white in dark, so a literal white glyph disappears
                // entirely on the dark scheme -- which has now happened twice.
                .foregroundStyle(isWorking || canSend ? Theme.onAccent : Color.secondary)
                .frame(width: 32, height: 32)
                .background {
                    Circle().fill(
                        isWorking || canSend
                            ? AnyShapeStyle(Theme.accent)
                            : AnyShapeStyle(Color.primary.opacity(0.12))
                    )
                }
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressButtonStyle())
        .disabled(!isWorking && !canSend)
        // A quick fade, not a bounce. The enable state flips on every keystroke
        // at the edge of an empty field; a spring there wobbles.
        .animation(.easeOut(duration: 0.15), value: canSend)
        .animation(.easeOut(duration: 0.15), value: isWorking)
        .accessibilityLabel(isWorking ? "Stop" : "Send")
    }
}

/// A picture on its way into the conversation.
///
/// `path` is nil while it uploads and the storage path once it has landed --
/// which is what the send button waits for.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let preview: UIImage
    var path: String?

    static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool {
        lhs.id == rhs.id && lhs.path == rhs.path
    }
}

/// A video on its way into the conversation, as its words.
///
/// `transcript` is nil while the sound is pulled out, uploaded and listened to;
/// Send waits for it, the same way it waits for a picture's upload.
struct PendingVideo: Identifiable, Equatable {
    let id = UUID()
    let poster: UIImage?
    let seconds: Int
    var transcript: String?

    static func == (lhs: PendingVideo, rhs: PendingVideo) -> Bool {
        lhs.id == rhs.id && lhs.transcript == rhs.transcript
    }
}

/// The press feel of a system control: a small, fast dip with no oscillation.
/// ChatGPT's press feedback is a nod, not a bounce.
struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The recording's loudness as bars, newest on the right: ChatGPT's waveform
/// while you talk, so you can see it hears you.
struct RecordingWave: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 2.5, height: max(3, CGFloat(level) * 24))
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.06), value: levels)
        .accessibilityLabel("Recording")
    }
}
