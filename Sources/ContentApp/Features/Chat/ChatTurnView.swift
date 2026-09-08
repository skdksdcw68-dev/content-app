import SwiftUI

/// One turn. The user's is a tinted capsule pushed right; the agent's is
/// typography on the page -- which is how every assistant on the platform
/// reads. Boxing a long answer makes it look like a quotation rather than a
/// reply.
struct ChatTurnView: View {
    let turn: ChatMessage

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 44)
                Text(turn.text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.accent.opacity(0.10))
                    }
                    .textSelection(.enabled)
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                if turn.isPending && turn.text.isEmpty {
                    // The trail once there is one. Before the first step the
                    // app genuinely has nothing to report, and inventing a line
                    // to fill the gap is the thing this replaced.
                    if turn.steps.isEmpty {
                        ThinkingIndicator()
                    } else {
                        TaskTrail(steps: turn.steps)
                    }
                } else if turn.failed {
                    Label(turn.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    // What it did, above what it concluded, folded away. More
                    // than one step means there was a path worth being able to
                    // check; a single step is not a story.
                    if turn.steps.count > 1 && !turn.isPending {
                        TaskTrailSummary(steps: turn.steps)
                    }

                    if !turn.text.isEmpty {
                        Text(turn.text)
                            .font(.subheadline)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        .font(.caption)
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
    @State private var isUp = false

    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: 11, height: 11)
            .scaleEffect(isUp ? 1.1 : 0.8)
            .opacity(isUp ? 1 : 0.55)
            // A fixed box, so the row does not shift as it breathes.
            .frame(width: 14, height: 14)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                    isUp = true
                }
            }
    }
}

/// The same trail after the answer has landed, folded to one line.
///
/// Kept rather than thrown away: an answer that took three reads and one that
/// took none look identical once the work is gone, and only one of them
/// deserves to be trusted. Folded, because the answer is what the person came
/// for and the receipt should not outrank it.
struct TaskTrailSummary: View {
    let steps: [TaskStep]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.indent")
                        .font(.caption2)
                    Text(TaskStep.summary(of: steps))
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide what it did" : "Show what it did")

            if isExpanded {
                TaskTrail(steps: steps)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// "Thinking", with the three dots that say it has not stalled.
struct ThinkingIndicator: View {
    var label = "Thinking"

    @State private var phase = 0

    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 4, height: 4)
                        .opacity(phase == index ? 1 : 0.3)
                }
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
        .accessibilityLabel(label)
    }
}
