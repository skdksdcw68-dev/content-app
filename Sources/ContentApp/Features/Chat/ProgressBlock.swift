import SwiftUI

/// A long job's steps, drawn as one line instead of a message each.
///
/// Netro, 31 Oct 2026, with a screenshot of a dozen "Making picture n of 6"
/// messages, each under its own copy / like / dislike / share row: "can we
/// make it as Claude please?" And on the first version, a tinted box with the
/// chevron at the far edge: "I want it to match Claude, not others like
/// ChatGPT ... only plain text and a dropdown ... to the right."
///
/// So it is Claude's shape exactly: one line of quiet grey text -- what it is
/// doing while it works, "Worked for 2m 14s" when it is done -- with a small
/// chevron right after the words. No box, no icon, no buttons; those belong to
/// the answer, not to the working. A tap opens the steps underneath.
struct ProgressBlock: View {
    let steps: [String]
    /// Still going: the block is the last thing in the conversation.
    let live: Bool
    /// When the first step was said, and when the job ended -- "Worked for
    /// 2m 14s", the way Claude says it. Nil for steps not yet read back.
    var started: Date? = nil
    var ended: Date? = nil

    @State private var open = false

    /// "42s", "3m 12s", "1h 05m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "(s)s" }
        if s < 3600 { return "(s / 60)m (String(format: "%02d", s % 60))s" }
        return "(s / 3600)h (String(format: "%02d", (s % 3600) / 60))m"
    }

    /// The line: the step it is on and for how long, or how long it took.
    static func headline(steps: [String], live: Bool, started: Date?, ended: Date?, now: Date) -> String {
        if live {
            let doing = steps.last.map { Step($0).firstLine } ?? "Working"
            guard let started else { return doing }
            return "(doing) · (duration(now.timeIntervalSince(started)))"
        }
        guard let started, let ended, ended > started else {
            return steps.count == 1 ? "Done in 1 step" : "Done in (steps.count) steps"
        }
        return "Worked for (duration(ended.timeIntervalSince(started)))"
    }

    private func headline(at now: Date) -> String {
        Self.headline(steps: steps, live: live, started: started, ended: ended, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { open.toggle() }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                HStack(spacing: 5) {
                    // Counts up once a second while it works.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(headline(at: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .contentTransition(.opacity)
                            .modifier(Shimmer(active: live))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headline(at: .now))
            .accessibilityHint(open ? "Hides the steps" : "Shows the steps")

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: .offset) { index, raw in
                        timelineRow(Step(raw), isLast: index == steps.count - 1 && live)
                    }
                    if !live {
                        timelineRow(Step(done: true), isLast: true)
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.2), value: steps.count)
    }

    /// One step: its icon on a thin line that joins it to the next.
    private func timelineRow(_ step: Step, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Group {
                    if isLast && live && !step.isDone {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: step.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(step.isWarning ? Color.orange : Color.secondary)
                    }
                }
                .frame(width: 20, height: 18)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            Text(step.text)
                .font(.footnote)
                .foregroundStyle(isLast && live ? Color.primary : Color.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A step's words without the emoji the server leads with, and an icon
    /// that says the same thing at this size.
    struct Step {
        let text: String
        let symbol: String
        let isWarning: Bool
        var isDone = false

        /// The step's first line, for the one-line header.
        var firstLine: String {
            text.split(whereSeparator: .isNewline).first.map(String.init) ?? text
        }

        /// The row that ends a finished job's steps.
        init(done: Bool) {
            text = "Done"
            symbol = "checkmark"
            isWarning = false
            isDone = done
        }

        /// By the emoji's first code point: "🖼️" is U+1F5BC plus a variation
        /// selector, and as Characters "🖼️".hasPrefix("🖼") is false.
        private static let symbols: [UInt32: String] = [
            0x1F4DD: "list.bullet.clipboard", // 📝
            0x2705: "checkmark.circle",       // ✅
            0x26A0: "exclamationmark.triangle", // ⚠️
            0x1F50E: "magnifyingglass",       // 🔎
            0x1F501: "arrow.clockwise",       // 🔁
            0x1F5BC: "photo",                 // 🖼️
            0x1F39E: "film.stack",            // 🎞️
            0x1F399: "waveform",              // 🎙️
            0x1F3AC: "film",                  // 🎬
        ]

        init(_ raw: String) {
            let lead = raw.unicodeScalars.first?.value ?? 0
            let match = Self.symbols[lead]
            symbol = match ?? "circle"
            isWarning = lead == 0x26A0
            // The emoji (with any variation selector) and the space after it.
            let words = match == nil ? raw : String(raw.drop { !$0.isLetter && !$0.isNumber && $0 != "“" && $0 != "\"" })
            text = words.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// A soft light that sweeps across the words while the job works, the way
/// Claude's "Thinking" line does. Still for Reduce Motion.
private struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -0.7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.6), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(40, geo.size.width * 0.5))
                        .offset(x: phase * geo.size.width)
                    }
                    .mask { content }
                    .allowsHitTesting(false)
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1.2 }
                }
        } else {
            content
        }
    }
}
