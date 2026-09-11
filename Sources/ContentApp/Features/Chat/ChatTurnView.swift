import SwiftUI

/// One turn. The user's is a tinted capsule pushed right; the agent's is
/// typography on the page -- which is how every assistant on the platform
/// reads. Boxing a long answer makes it look like a quotation rather than a
/// reply.
struct ChatTurnView: View {
    let turn: ChatMessage
    /// Answering a question is the same as saying it out loud, so it goes back
    /// as an ordinary turn rather than through a side channel. The transcript
    /// then reads the way the conversation actually went.
    var onAnswer: (ChatQuestion, String) -> Void = { _, _ in }
    /// Nil means Auto: the person declined to choose, which is a choice.
    var onChooseModel: (ModelChoice?) -> Void = { _ in }
    var onExport: (Artifact, String) -> Void = { _, _ in }
    var onAnimate: (Artifact) -> Void = { _ in }
    var onApprove: (Artifact) -> Void = { _ in }
    /// A run this turn started has ended while it was being watched.
    var onRunFinished: (UUID) -> Void = { _ in }

    var body: some View {
        switch turn.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !turn.attachments.isEmpty {
                    // Their pictures sit on their side, above what they said.
                    AttachmentStrip(paths: turn.attachments, trailing: true)
                }
                HStack {
                    Spacer(minLength: 44)
                    Text(turn.text)
                        .font(.body)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Theme.accent.opacity(0.10))
                        }
                        .textSelection(.enabled)
                }
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                if turn.isPending && turn.text.isEmpty {
                    // A dot while it thinks; a line only while it is doing
                    // real work -- making, pricing, researching. Nothing is
                    // announced for an ordinary answer.
                    if turn.steps.isEmpty {
                        ThinkingIndicator()
                    } else {
                        TaskTrail(steps: turn.steps)
                    }
                } else if turn.failed {
                    Label(turn.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                } else {
                    // The steps are gone once the answer lands. They were
                    // there to show it was working; afterwards only the answer
                    // matters, and a folded "3 steps" above every reply was
                    // the agent narrating itself.
                    if !turn.text.isEmpty {
                        Text(turn.text)
                            .font(.body)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let offer = turn.offer {
                        ModelPicker(
                            offer: offer,
                            chosen: turn.chosenModel
                        ) { onChooseModel($0) }
                    }

                    ForEach(turn.questions) { question in
                        QuestionCard(
                            question: question,
                            answer: turn.answered[question.key]
                        ) { onAnswer(question, $0) }
                    }

                    if let runId = turn.runId {
                        RunCard(runId: runId, kind: turn.runKind) { onRunFinished(runId) }
                    }

                    if let artifactId = turn.artifactId {
                        ArtifactCard(
                            artifactId: artifactId,
                            onExport: onExport,
                            onAnimate: onAnimate,
                            onApprove: onApprove
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The models that could do it, with what is actually known about each.
///
/// Names alone would be useless: "Sora 2" means nothing next to "720p only,
/// 4/8/12 seconds, about four minutes". So every row carries the constraints
/// that were read off the provider's own schema, and the price in whatever unit
/// that provider bills in.
///
/// "Cost not stated" appears a lot and that is correct. Higgsfield's REST
/// surface quotes no price anywhere, and an invented figure would be worse than
/// the gap because somebody would choose on it.
///
/// Auto is first and pre-selected. Most people should not have to care, and the
/// ones who do can see exactly what Auto would have taken and why.
private struct ModelPicker: View {
    let offer: ModelOffer
    let chosen: String?
    let onChoose: (ModelChoice?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let chosen {
                Label(chosen, systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.accent)
            } else {
                if let auto = offer.auto {
                    Button { onChoose(nil) } label: {
                        AutoRow(auto: auto)
                    }
                    .buttonStyle(PressButtonStyle())
                }

                ForEach(offer.options) { option in
                    Button { onChoose(option) } label: {
                        ModelRow(option: option)
                    }
                    .buttonStyle(PressButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AutoRow: View {
    let auto: ModelChoice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.accent))

            VStack(alignment: .leading, spacing: 2) {
                Text("Let me choose")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(auto.reason ?? "Picks the best available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.accent.opacity(0.10))
        }
    }
}

private struct ModelRow: View {
    let option: ModelChoice

    /// The facts, in the order somebody scanning would want them.
    private var facts: [String] {
        var out: [String] = [option.cost.label]
        if let resolutions = option.constraints.resolutions, !resolutions.isEmpty {
            out.append(resolutions.joined(separator: "/"))
        }
        if let durations = option.constraints.durations, !durations.isEmpty {
            out.append(durations.map(String.init).joined(separator: "/") + "s")
        }
        if let seconds = option.constraints.typicalSeconds {
            out.append("~\(max(1, seconds / 60)) min")
        }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if option.recommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    }
                }

                Text(facts.joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let notes = option.constraints.notes, !notes.isEmpty {
                    Text(notes.joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.surface)
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

/// One breathing blue dot while the reply is on its way.
///
/// It used to say "Thinking" with three dots after it, on every message --
/// a word for something that takes a second, repeated until it read as the
/// app talking about itself. A dot says the same thing without saying it.
struct ThinkingIndicator: View {
    @State private var isUp = false

    var body: some View {
        Circle()
            .fill(Color.blue)
            .frame(width: 12, height: 12)
            .scaleEffect(isUp ? 1 : 0.7)
            .opacity(isUp ? 1 : 0.5)
            // A fixed box, so the line below does not shift as it breathes.
            .frame(width: 16, height: 16)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    isUp = true
                }
            }
            .padding(.vertical, 4)
            .accessibilityLabel("Working on it")
    }
}
