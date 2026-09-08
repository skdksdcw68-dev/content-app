import SwiftUI
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
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool

    private var hasRequest: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool { hasRequest && !isWorking }

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
    }

    private var capsule: some View {
        HStack(alignment: .bottom, spacing: 6) {
            plusButton

            TextField("Ask Autocast", text: $text, axis: .vertical)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    // Neutral in every state. A border that turns accent-
                    // coloured when there is text is a custom-app tell; the
                    // real thing only brightens a touch on focus.
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            Color(uiColor: .separator).opacity(isFocused ? 0.7 : 0.45),
                            lineWidth: 0.5
                        )
                }
        }
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        // A new line grows the capsule smoothly instead of snapping it a line
        // taller. Keyed to the text because that is the only thing that changes
        // the line count; on an ordinary keystroke nothing moves.
        .animation(.easeOut(duration: 0.18), value: text)
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
