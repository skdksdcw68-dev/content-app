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
    var onRemoveAttachment: (UUID) -> Void = { _ in }
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool

    private var hasRequest: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A picture on its own is a message -- "here, do something with this" --
    /// so it sends with nothing typed. Never while one is still uploading:
    /// sending then would send the message without it, and the person would
    /// think it had been seen.
    private var canSend: Bool {
        (hasRequest || !attachments.isEmpty) && !isWorking && attachments.allSatisfy { $0.path != nil }
    }

    /// Wide as soon as the field is focused, not only once there is text.
    /// Measured off ChatGPT: it widens *during* the keyboard's rise, so the two
    /// read as one gesture; waiting for the first character made ours a
    /// separate, later event.
    private var isExpanded: Bool { isFocused || hasRequest }

    var body: some View {
        capsule
            .padding(.horizontal, isExpanded ? 12 : 34)
            .padding(.top, 6)
            .animation(.easeOut(duration: 0.22), value: isExpanded)
            .sensoryFeedback(.impact(weight: .light), trigger: showsOptions)
            .sensoryFeedback(.impact(weight: .medium), trigger: isWorking)
            .onChange(of: focusToken) { _, _ in isFocused = true }
    }

    private var capsule: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                pendingStrip
            }

            HStack(alignment: .bottom, spacing: 6) {
                plusButton

                TextField(attachments.isEmpty ? "Ask Autocast" : "Say what to do with it", text: $text, axis: .vertical)
                    .font(.system(size: 16))
                    .lineSpacing(3)
                    // One line at rest, growing to six, then scrolling inside
                    // itself. The buttons stay on the bottom edge while it grows.
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 7)
                    .id(resetToken)

                actionButton
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
